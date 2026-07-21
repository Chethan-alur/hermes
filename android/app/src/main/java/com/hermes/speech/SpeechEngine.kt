package com.hermes.speech

import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log

sealed class SpeechEvent {
    object ListeningStarted : SpeechEvent()
    object ListeningStopped : SpeechEvent()
    object ReadyForSpeech : SpeechEvent()
    object BeginningOfSpeech : SpeechEvent()
    object EndOfSpeech : SpeechEvent()
    object Timeout : SpeechEvent()
    data class PartialResult(val text: String, val sequence: Int) : SpeechEvent()
    data class FinalResult(val text: String, val confidence: Float) : SpeechEvent()
    data class Error(val code: Int, val message: String) : SpeechEvent()
    /** Diagnostic breadcrumb surfaced to the companion (which mic, audio detected, fallback, …). */
    data class Status(
        val event: String,          // "mic" | "speech_detected" | "mic_fallback" | "no_speech"
        val mic: String? = null,    // "bluetooth" | "builtin"
        val device: String? = null, // e.g. "Jabra Evolve 75 SE"
        val detail: String? = null, // human-readable summary
    ) : SpeechEvent()
}

interface SpeechEngine {
    fun startListening(onEvent: (SpeechEvent) -> Unit)
    fun stopListening()
    fun destroy()
}

/**
 * Continuous, push-to-talk friendly wrapper around [SpeechRecognizer].
 *
 * Android's SpeechRecognizer is a single-utterance API that endpoints on the first pause,
 * so to capture while the hotkey is held we run a session ([startListening]..[stopListening])
 * and restart the recognizer when it endpoints, accumulating text across segments. A single
 * [SpeechEvent.FinalResult] (accumulated text, with the last partial folded in) is emitted
 * only on stop.
 *
 * Recognizer selection:
 *  - Offline (default): the on-device recognizer (createOnDeviceSpeechRecognizer) -- on a
 *    Pixel this is the good Tensor model, far better than the device's default basic engine.
 *    If the on-device model for the language is not downloaded (ERROR_LANGUAGE_UNAVAILABLE),
 *    we trigger a download and fall back to the default recognizer for that session.
 *  - Online: the default recognizer with EXTRA_PREFER_OFFLINE=false.
 *
 * The recognizer is created lazily, and ERROR_RECOGNIZER_BUSY is handled with backoff +
 * recreate + give-up (never a tight loop, which jams the system recognition service).
 */
class AndroidSpeechEngine(private val context: Context) : SpeechEngine {
    private var recognizer: SpeechRecognizer? = null
    private var listener: ((SpeechEvent) -> Unit)? = null
    private var sequenceCounter = 0

    @Volatile private var sessionActive = false
    @Volatile private var segmentRunning = false
    @Volatile private var finalized = false
    @Volatile private var busyCount = 0
    private var usingOnDevice: Boolean? = null          // null = no recognizer yet
    private var forceDefaultThisSession = false         // on-device model missing -> fall back
    private val accumulated = StringBuilder()
    private var lastPartial = ""
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var firstReadyOfSession = false
    private var toneGen: ToneGenerator? = null
    private var audioManager: AudioManager? = null
    @Volatile private var routedToCommDevice = false

    // Auto-fallback: if a routed Bluetooth mic yields no speech quickly (e.g. the user speaks
    // into the phone while a BT headset is connected), drop it and re-capture on the built-in
    // mic for the rest of the session. (REQ-FUNC-013)
    @Volatile private var forceBuiltInMic = false
    @Volatile private var autoFallbackEnabled = true   // only auto mic-preference falls back
    @Volatile private var sessionHeardSpeech = false
    private var micFallbackRunnable: Runnable? = null
    private var routedDeviceName: String? = null       // BT device name while routed, for diagnostics
    @Volatile private var peakRmsDb = NO_RMS           // highest audio level seen this session (dB)
    private var savedAudioMode: Int? = null            // audio mode to restore after BT SCO capture

    companion object {
        private const val TAG = "AndroidSpeechEngine"
        private const val SILENCE_MILLIS = 10000
        private const val LANGUAGE = "en-IN"
        const val PREFS = "hermes_prefs"
        const val KEY_PREFER_OFFLINE = "prefer_offline"
        const val KEY_MIC_PREF = "mic_preference"   // "auto" | "builtin" | "bluetooth"

        private const val RESTART_MS = 150L
        private const val BUSY_BACKOFF_MS = 450L
        private const val RECREATE_AT_BUSY = 3
        private const val GIVE_UP_BUSY = 8

        // Audible cues played by the phone. STREAM_ALARM stays audible under silent/DND,
        // which matters when the phone is used as a desk mic. Java static-final ints can't
        // be a Kotlin `const val`, so the stream/tone type are plain `val`.
        private val CUE_STREAM = AudioManager.STREAM_ALARM
        private val CUE_START_TONE = ToneGenerator.TONE_PROP_BEEP
        private val CUE_STOP_TONE = ToneGenerator.TONE_PROP_BEEP2
        private const val CUE_VOLUME = 80          // 0..100
        private const val CUE_START_MS = 150
        private const val CUE_STOP_MS = 120

        // Give a just-engaged Bluetooth SCO/LE link a moment to come up before the first
        // segment starts capturing, so the opening words are not clipped. (REQ-FUNC-013)
        private const val SCO_WARMUP_MS = 1000L

        // If a Bluetooth mic is routed but no speech is detected within this window, fall back
        // to the built-in mic for the rest of the session. (REQ-FUNC-013)
        private const val MIC_SILENCE_FALLBACK_MS = 2500L

        // Sentinel for "no audio level reported yet" (onRmsChanged never fired => silent mic).
        private const val NO_RMS = -160f

        /**
         * Preferred Bluetooth microphone type among the currently available communication-device
         * types: LE-Audio headset first, then classic HFP/SCO, else null (use the built-in mic).
         * Pure and framework-free so it is unit-testable. (REQ-FUNC-013)
         */
        internal fun preferredBluetoothInputType(availableTypes: List<Int>): Int? = when {
            availableTypes.contains(AudioDeviceInfo.TYPE_BLE_HEADSET) -> AudioDeviceInfo.TYPE_BLE_HEADSET
            availableTypes.contains(AudioDeviceInfo.TYPE_BLUETOOTH_SCO) -> AudioDeviceInfo.TYPE_BLUETOOTH_SCO
            else -> null
        }
    }

    init {
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            Log.e(TAG, "Speech recognition unavailable on this device.")
        }
        // Recognizer is created lazily in ensureRecognizer() on first use.
    }

    override fun startListening(onEvent: (SpeechEvent) -> Unit) {
        this.listener = onEvent
        this.sequenceCounter = 0
        this.busyCount = 0
        this.accumulated.setLength(0)
        this.lastPartial = ""
        this.finalized = false
        this.forceDefaultThisSession = false
        this.firstReadyOfSession = true
        val pref = micPreference()
        this.autoFallbackEnabled = (pref == "auto")
        this.forceBuiltInMic = (pref == "builtin")
        this.sessionHeardSpeech = false
        this.peakRmsDb = NO_RMS
        this.routedDeviceName = null
        this.sessionActive = true
        Log.i(TAG, "Mic preference: $pref")
        // "builtin" -> never route Bluetooth (phone mic immediately, no fallback delay). Clear any
        // stale routing first so the built-in path never inherits a prior session's Bluetooth state.
        val btRouted = if (forceBuiltInMic) { clearBluetoothRouting(); false } else routeMicToBluetoothHeadset()
        ensureRecognizer(prefersOffline())
        listener?.invoke(SpeechEvent.ListeningStarted)
        emitMicStatus()
        Log.i(TAG, "Session started (continuous capture).")
        // If we just engaged a Bluetooth mic, let the link warm up before the first segment.
        if (btRouted) mainHandler.postDelayed({ startSegment() }, SCO_WARMUP_MS) else startSegment()
    }

    override fun stopListening() {
        if (!sessionActive && finalized) return
        sessionActive = false
        Log.i(TAG, "Session stop requested; finalizing.")
        try { recognizer?.stopListening() } catch (e: Exception) {
            Log.w(TAG, "stopListening ignored exception: ${e.message}")
        }
        if (!segmentRunning) emitFinal()
        else mainHandler.postDelayed({ emitFinal() }, 1200)
    }

    override fun destroy() {
        sessionActive = false
        finalized = true
        mainHandler.removeCallbacksAndMessages(null)
        clearBluetoothRouting()
        try { recognizer?.destroy() } catch (_: Exception) {}
        recognizer = null
        try { toneGen?.release() } catch (_: Exception) {}
        toneGen = null
        listener = null
        segmentRunning = false
    }

    // --- Configuration helpers ---------------------------------------------------

    private fun prefersOffline(): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_PREFER_OFFLINE, true)

    /** User's microphone choice: "auto" (default), "builtin" (phone), or "bluetooth". */
    private fun micPreference(): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_MIC_PREF, "auto") ?: "auto"

    /**
     * Route microphone capture to a connected Bluetooth headset for the session. A Bluetooth headset
     * exposes audio output over A2DP but its microphone only over HFP/SCO (or LE-Audio); without
     * explicitly selecting it as the communication device, [SpeechRecognizer] keeps capturing from
     * the built-in mic. Returns true if a Bluetooth input was engaged. (REQ-FUNC-013)
     */
    private fun routeMicToBluetoothHeadset(): Boolean {
        clearBluetoothRouting()   // defensively drop any stale routing from a prior session
        return try {
            val am = audioManager
                ?: context.getSystemService(AudioManager::class.java)?.also { audioManager = it }
                ?: return false
            val chosenType = preferredBluetoothInputType(am.availableCommunicationDevices.map { it.type })
                ?: run {
                    Log.i(TAG, "No Bluetooth headset mic available; using default mic.")
                    return false
                }
            val device = am.availableCommunicationDevices.first { it.type == chosenType }
            // A Bluetooth HFP/SCO mic only captures while the audio system is in communication
            // mode; without this, setCommunicationDevice "engages" but the mic stays silent.
            savedAudioMode = am.mode
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            val ok = am.setCommunicationDevice(device)
            if (!ok) { savedAudioMode?.let { am.mode = it }; savedAudioMode = null }
            routedToCommDevice = ok
            routedDeviceName = if (ok) device.productName?.toString() else null
            Log.i(TAG, "Bluetooth mic routing: device=${device.productName} type=${device.type} engaged=$ok mode=IN_COMMUNICATION")
            ok
        } catch (e: Exception) {
            Log.w(TAG, "Bluetooth mic routing failed: ${e.message}")
            false
        }
    }

    /** Release any Bluetooth communication-device routing so the headset leaves call mode. */
    private fun clearBluetoothRouting() {
        if (!routedToCommDevice) return
        try {
            audioManager?.clearCommunicationDevice()
            savedAudioMode?.let { audioManager?.mode = it }   // leave call mode
            Log.i(TAG, "Cleared Bluetooth mic routing.")
        } catch (e: Exception) {
            Log.w(TAG, "clearCommunicationDevice failed: ${e.message}")
        } finally {
            savedAudioMode = null
            routedToCommDevice = false
        }
    }

    private fun buildRecognizeIntent(preferOffline: Boolean): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, LANGUAGE)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, LANGUAGE)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            // Add unspoken punctuation and capitalization, like Gboard voice typing.
            putExtra(RecognizerIntent.EXTRA_ENABLE_FORMATTING, RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, preferOffline)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, SILENCE_MILLIS)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, SILENCE_MILLIS)
        }

    private fun ensureRecognizer(preferOffline: Boolean) {
        val wantOnDevice = preferOffline &&
            !forceDefaultThisSession &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        if (recognizer != null && usingOnDevice == wantOnDevice) return
        try { recognizer?.destroy() } catch (_: Exception) {}
        recognizer = try {
            when {
                wantOnDevice -> SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
                SpeechRecognizer.isRecognitionAvailable(context) -> SpeechRecognizer.createSpeechRecognizer(context)
                else -> null
            }
        } catch (e: Exception) {
            Log.e(TAG, "createRecognizer failed: ${e.message}"); null
        }
        usingOnDevice = if (recognizer != null) wantOnDevice else null
        if (recognizer != null) setupRecognitionListener()
        Log.i(TAG, "Recognizer=${if (usingOnDevice == true) "on-device" else "default"} available=${recognizer != null}")
    }

    private fun recreateRecognizer() {
        try { recognizer?.destroy() } catch (_: Exception) {}
        recognizer = null
        usingOnDevice = null
        ensureRecognizer(prefersOffline())
    }

    /** Ask the system to download the on-device model for our language (best effort). */
    private fun triggerOnDeviceDownload() {
        try {
            if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) return
            val dl = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            dl.triggerModelDownload(buildRecognizeIntent(true))
            Log.i(TAG, "Requested on-device model download for $LANGUAGE.")
            mainHandler.postDelayed({ try { dl.destroy() } catch (_: Exception) {} }, 60000)
        } catch (e: Exception) {
            Log.w(TAG, "triggerModelDownload failed: ${e.message}")
        }
    }

    // --- Session / segment control ----------------------------------------------

    private fun startSegment() {
        if (!sessionActive) return
        segmentRunning = true
        lastPartial = ""
        val preferOffline = prefersOffline()
        Log.i(TAG, "Segment start (lang=$LANGUAGE offline=$preferOffline onDevice=${usingOnDevice == true})")
        try {
            recognizer?.startListening(buildRecognizeIntent(preferOffline))
        } catch (e: Exception) {
            Log.w(TAG, "startListening failed: ${e.message}")
            scheduleRestart(BUSY_BACKOFF_MS)
        }
        if (autoFallbackEnabled && routedToCommDevice && !sessionHeardSpeech && !forceBuiltInMic) scheduleMicFallbackCheck()
    }

    private fun scheduleRestart(delayMs: Long) {
        if (!sessionActive) return
        mainHandler.postDelayed({ startSegment() }, delayMs)
    }

    /**
     * If a Bluetooth mic was engaged but no speech is heard within [MIC_SILENCE_FALLBACK_MS]
     * (e.g. the user speaks into the phone while a BT headset is connected), drop the Bluetooth
     * routing and re-capture on the built-in mic for the rest of the session. (REQ-FUNC-013)
     */
    private fun scheduleMicFallbackCheck() {
        micFallbackRunnable?.let { mainHandler.removeCallbacks(it) }
        val r = Runnable {
            if (!sessionActive || finalized) return@Runnable
            if (sessionHeardSpeech || !routedToCommDevice || forceBuiltInMic) return@Runnable
            Log.w(TAG, "No speech via Bluetooth mic within ${MIC_SILENCE_FALLBACK_MS}ms; " +
                       "falling back to the built-in mic for this session.")
            forceBuiltInMic = true
            val btName = routedDeviceName ?: "headset"
            clearBluetoothRouting()
            listener?.invoke(SpeechEvent.Status("mic_fallback", "builtin", null,
                "No audio on Bluetooth mic ($btName) within ${MIC_SILENCE_FALLBACK_MS}ms; switched to built-in mic"))
            recreateRecognizer()   // drop the BT-bound recognizer; the next segment uses the built-in mic
            segmentRunning = false
            scheduleRestart(RESTART_MS)
        }
        micFallbackRunnable = r
        mainHandler.postDelayed(r, MIC_SILENCE_FALLBACK_MS)
    }

    /** Speech was detected on the current input, so cancel any pending Bluetooth-mic fallback. */
    private fun markSpeechHeard() {
        if (!sessionHeardSpeech) {
            sessionHeardSpeech = true
            micFallbackRunnable?.let { mainHandler.removeCallbacks(it) }
            listener?.invoke(SpeechEvent.Status("speech_detected", currentMicLabel(), currentMicDevice(),
                "Audio detected on ${currentMicLabel()} mic"))
        }
    }

    private fun currentMicLabel(): String = if (routedToCommDevice) "bluetooth" else "builtin"
    // Device name only while actually routed to Bluetooth, so a fallen-back session never
    // mislabels the built-in mic with the headset's name.
    private fun currentMicDevice(): String? = if (routedToCommDevice) routedDeviceName else null

    /** Tell the companion which microphone the session is capturing from. */
    private fun emitMicStatus() {
        val detail = if (routedToCommDevice) "Bluetooth mic: ${routedDeviceName ?: "headset"}" else "Built-in phone mic"
        listener?.invoke(SpeechEvent.Status("mic", currentMicLabel(), currentMicDevice(), detail))
    }

    private fun flushPartial() {
        val p = lastPartial.trim()
        if (p.isNotEmpty()) {
            if (accumulated.isNotEmpty()) accumulated.append(" ")
            accumulated.append(p)
        }
        lastPartial = ""
    }

    private fun continueOrFinalize() {
        if (sessionActive) {
            flushPartial()
            scheduleRestart(RESTART_MS)
        } else {
            emitFinal()
        }
    }

    private fun emitFinal() {
        if (finalized) return
        finalized = true
        segmentRunning = false
        flushPartial()
        val text = accumulated.toString().trim()
        Log.i(TAG, "Final (accumulated): \"$text\"")
        if (text.isEmpty()) {
            val level = if (peakRmsDb > NO_RMS) "peak level %.1f dB".format(peakRmsDb) else "no audio frames received"
            listener?.invoke(SpeechEvent.Status("no_speech", currentMicLabel(), currentMicDevice(),
                "No speech captured on ${currentMicLabel()} mic ($level)"))
        }
        Log.i(TAG, "Stopped cue played.")
        playCue(CUE_STOP_TONE, CUE_STOP_MS)
        listener?.invoke(SpeechEvent.ListeningStopped)
        listener?.invoke(SpeechEvent.FinalResult(text, 1.0f))
        clearBluetoothRouting()
    }

    /** ERROR_RECOGNIZER_BUSY / ERROR_CLIENT: back off, recreate, and eventually give up. */
    private fun handleBusy(error: Int) {
        busyCount++
        when {
            busyCount >= GIVE_UP_BUSY -> {
                sessionActive = false
                finalized = true
                clearBluetoothRouting()
                Log.e(TAG, "Recognizer stuck busy after $busyCount tries; giving up.")
                listener?.invoke(SpeechEvent.Error(error, "Recognizer busy - please try again"))
            }
            busyCount == RECREATE_AT_BUSY -> {
                Log.w(TAG, "Recognizer busy x$busyCount; recreating recognizer.")
                recreateRecognizer()
                scheduleRestart(BUSY_BACKOFF_MS)
            }
            else -> scheduleRestart(BUSY_BACKOFF_MS)
        }
    }

    /** On-device model missing: download it and fall back to the default recognizer now. */
    private fun handleLanguageUnavailable(error: Int) {
        if (usingOnDevice == true && !forceDefaultThisSession) {
            Log.w(TAG, "On-device $LANGUAGE model unavailable; downloading + falling back to default.")
            triggerOnDeviceDownload()
            forceDefaultThisSession = true
            ensureRecognizer(prefersOffline())   // wantOnDevice now false -> default recognizer
            scheduleRestart(BUSY_BACKOFF_MS)
        } else {
            sessionActive = false
            finalized = true
            clearBluetoothRouting()
            listener?.invoke(SpeechEvent.Error(error, getErrorMessage(error)))
        }
    }

    private fun setupRecognitionListener() {
        recognizer?.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {
                busyCount = 0
                if (firstReadyOfSession) {
                    firstReadyOfSession = false
                    Log.i(TAG, "Listening cue played (start).")
                    playCue(CUE_START_TONE, CUE_START_MS)
                }
                listener?.invoke(SpeechEvent.ReadyForSpeech)
            }

            override fun onBeginningOfSpeech() {
                markSpeechHeard()
                listener?.invoke(SpeechEvent.BeginningOfSpeech)
            }

            override fun onRmsChanged(rmsdB: Float) {
                if (rmsdB > peakRmsDb) peakRmsDb = rmsdB
            }
            override fun onBufferReceived(buffer: ByteArray?) {}

            override fun onEndOfSpeech() {
                listener?.invoke(SpeechEvent.EndOfSpeech)
            }

            override fun onError(error: Int) {
                segmentRunning = false
                if (!sessionActive) {
                    emitFinal()
                    return
                }
                Log.i(TAG, "Segment error: ${getErrorMessage(error)} (code $error)")
                when (error) {
                    SpeechRecognizer.ERROR_NO_MATCH,
                    SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> {
                        busyCount = 0
                        continueOrFinalize()
                    }
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY,
                    SpeechRecognizer.ERROR_CLIENT -> handleBusy(error)
                    SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE,
                    SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> handleLanguageUnavailable(error)
                    else -> {
                        sessionActive = false
                        finalized = true
                        clearBluetoothRouting()
                        val msg = getErrorMessage(error)
                        Log.e(TAG, "Speech recognition error: $msg (code $error)")
                        listener?.invoke(SpeechEvent.Error(error, msg))
                    }
                }
            }

            override fun onResults(results: Bundle?) {
                segmentRunning = false
                busyCount = 0
                val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val segText = if (!matches.isNullOrEmpty()) matches[0] else null
                if (!segText.isNullOrBlank()) {
                    markSpeechHeard()
                    if (accumulated.isNotEmpty()) accumulated.append(" ")
                    accumulated.append(segText.trim())
                    lastPartial = ""
                }
                Log.i(TAG, "Segment result: \"${segText ?: ""}\" | accumulated: \"$accumulated\"")
                continueOrFinalize()
            }

            override fun onPartialResults(partialResults: Bundle?) {
                val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                if (!matches.isNullOrEmpty()) {
                    markSpeechHeard()
                    lastPartial = matches[0]
                    val prefix = if (accumulated.isNotEmpty()) accumulated.toString() + " " else ""
                    sequenceCounter++
                    listener?.invoke(SpeechEvent.PartialResult((prefix + lastPartial).trim(), sequenceCounter))
                }
            }

            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
    }

    /** One-shot audible cue played by the phone (start beep when ready, stop beep on finalize). */
    private fun playCue(tone: Int, durationMs: Int) {
        try {
            val tg = toneGen ?: ToneGenerator(CUE_STREAM, CUE_VOLUME).also { toneGen = it }
            tg.startTone(tone, durationMs)
        } catch (e: RuntimeException) {
            Log.w(TAG, "Audio cue unavailable: ${e.message}")
            try { toneGen?.release() } catch (_: Exception) {}
            toneGen = null
        }
    }

    private fun getErrorMessage(errorCode: Int): String {
        return when (errorCode) {
            SpeechRecognizer.ERROR_AUDIO -> "Audio recording error"
            SpeechRecognizer.ERROR_CLIENT -> "Client side error"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Insufficient permissions"
            SpeechRecognizer.ERROR_NETWORK -> "Network error"
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Network timeout"
            SpeechRecognizer.ERROR_NO_MATCH -> "No speech match found"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Recognition service busy"
            SpeechRecognizer.ERROR_SERVER -> "Server error"
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech input detected"
            SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "Language not supported"
            SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "Language model not downloaded"
            else -> "Unknown speech recognition error"
        }
    }
}
