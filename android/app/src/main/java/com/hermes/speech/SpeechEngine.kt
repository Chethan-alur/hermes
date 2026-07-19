package com.hermes.speech

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import java.util.Locale

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
}

interface SpeechEngine {
    fun startListening(onEvent: (SpeechEvent) -> Unit)
    fun stopListening()
    fun destroy()
}

/**
 * Continuous, push-to-talk friendly wrapper around [SpeechRecognizer].
 *
 * Android's SpeechRecognizer is a single-utterance API: it endpoints on the first pause
 * and stops on its own. To capture for as long as the user holds the hotkey we run it as a
 * session ([startListening] .. [stopListening]) and transparently restart the recognizer
 * each time it endpoints, accumulating text across segments.
 *
 * Robustness: the recognizer does not reliably deliver onResults when we force a stop
 * mid-utterance, so we also track the latest partial for the current segment and fold it
 * into the accumulated text. A single [SpeechEvent.FinalResult] with the accumulated text
 * is emitted only on [stopListening] (i.e. key release), which is what gets pasted.
 */
class AndroidSpeechEngine(private val context: Context) : SpeechEngine {
    private var recognizer: SpeechRecognizer? = null
    private var listener: ((SpeechEvent) -> Unit)? = null
    private var sequenceCounter = 0

    @Volatile private var sessionActive = false      // between start and stop commands
    @Volatile private var segmentRunning = false     // a recognizer segment is live
    @Volatile private var finalized = false          // the final result has been emitted
    private val accumulated = StringBuilder()         // text from finalized/flushed segments
    private var lastPartial = ""                      // latest partial of the current segment
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        private const val TAG = "AndroidSpeechEngine"
        // Tolerate long pauses within a single segment so we restart (and drop audio) as
        // rarely as possible. Note: Google's recognizer may ignore these hints.
        private const val SILENCE_MILLIS = 10000
    }

    init {
        if (SpeechRecognizer.isRecognitionAvailable(context)) {
            recognizer = SpeechRecognizer.createSpeechRecognizer(context)
            setupRecognitionListener()
        } else {
            Log.e(TAG, "Speech recognition unavailable on this device.")
        }
    }

    override fun startListening(onEvent: (SpeechEvent) -> Unit) {
        this.listener = onEvent
        this.sequenceCounter = 0
        this.accumulated.setLength(0)
        this.lastPartial = ""
        this.finalized = false
        this.sessionActive = true
        listener?.invoke(SpeechEvent.ListeningStarted)
        Log.i(TAG, "Session started (continuous capture).")
        startSegment()
    }

    override fun stopListening() {
        if (!sessionActive && finalized) return
        sessionActive = false
        Log.i(TAG, "Session stop requested; finalizing.")
        try { recognizer?.stopListening() } catch (e: Exception) {
            Log.w(TAG, "stopListening ignored exception: ${e.message}")
        }
        if (!segmentRunning) {
            emitFinal()
        } else {
            // Give onResults a brief chance; otherwise finalize from the last partial.
            mainHandler.postDelayed({ emitFinal() }, 1200)
        }
    }

    override fun destroy() {
        sessionActive = false
        finalized = true
        mainHandler.removeCallbacksAndMessages(null)
        recognizer?.destroy()
        recognizer = null
        listener = null
        segmentRunning = false
    }

    private fun startSegment() {
        if (!sessionActive) return
        segmentRunning = true
        lastPartial = ""
        Log.i(TAG, "Segment start")
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault())
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true) // on-device (Tensor G3)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, SILENCE_MILLIS)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, SILENCE_MILLIS)
        }
        try {
            recognizer?.startListening(intent)
        } catch (e: Exception) {
            Log.w(TAG, "startListening failed: ${e.message}")
            restartSegmentDelayed()
        }
    }

    private fun restartSegmentDelayed() {
        if (!sessionActive) return
        mainHandler.postDelayed({ startSegment() }, 150)
    }

    /** Fold any pending partial (speech not confirmed by onResults) into accumulated text. */
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
            flushPartial()          // preserve this segment's speech before restarting
            restartSegmentDelayed()
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
        listener?.invoke(SpeechEvent.ListeningStopped)
        listener?.invoke(SpeechEvent.FinalResult(text, 1.0f))
    }

    private fun setupRecognitionListener() {
        recognizer?.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {
                listener?.invoke(SpeechEvent.ReadyForSpeech)
            }

            override fun onBeginningOfSpeech() {
                listener?.invoke(SpeechEvent.BeginningOfSpeech)
            }

            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}

            override fun onEndOfSpeech() {
                Log.i(TAG, "onEndOfSpeech (recognizer endpointed)")
                listener?.invoke(SpeechEvent.EndOfSpeech)
            }

            override fun onError(error: Int) {
                segmentRunning = false
                if (!sessionActive) {
                    emitFinal()   // user released the key; finalize with what we have
                    return
                }
                Log.i(TAG, "Segment error: ${getErrorMessage(error)} (code $error); sessionActive=$sessionActive")
                when (error) {
                    // Benign endpoints during a hold: no speech yet, a pause, or a busy
                    // recognizer between restarts -> keep the session alive.
                    SpeechRecognizer.ERROR_NO_MATCH,
                    SpeechRecognizer.ERROR_SPEECH_TIMEOUT,
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY,
                    SpeechRecognizer.ERROR_CLIENT -> continueOrFinalize()
                    else -> {
                        // Fatal (permissions, audio, server): stop and report.
                        sessionActive = false
                        finalized = true
                        val msg = getErrorMessage(error)
                        Log.e(TAG, "Speech recognition error: $msg (code $error)")
                        listener?.invoke(SpeechEvent.Error(error, msg))
                    }
                }
            }

            override fun onResults(results: Bundle?) {
                segmentRunning = false
                val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val segText = if (!matches.isNullOrEmpty()) matches[0] else null
                if (!segText.isNullOrBlank()) {
                    if (accumulated.isNotEmpty()) accumulated.append(" ")
                    accumulated.append(segText.trim())
                    lastPartial = ""    // onResults supersedes the partial for this segment
                }
                Log.i(TAG, "Segment result: \"${segText ?: ""}\" | accumulated: \"$accumulated\"")
                continueOrFinalize()
            }

            override fun onPartialResults(partialResults: Bundle?) {
                val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                if (!matches.isNullOrEmpty()) {
                    lastPartial = matches[0]
                    val prefix = if (accumulated.isNotEmpty()) accumulated.toString() + " " else ""
                    sequenceCounter++
                    listener?.invoke(SpeechEvent.PartialResult((prefix + lastPartial).trim(), sequenceCounter))
                }
            }

            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
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
            else -> "Unknown speech recognition error"
        }
    }
}
