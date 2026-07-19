package com.hermes.speech

import android.content.Context
import android.content.Intent
import android.os.Bundle
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

class AndroidSpeechEngine(private val context: Context) : SpeechEngine {
    private var recognizer: SpeechRecognizer? = null
    private var listener: ((SpeechEvent) -> Unit)? = null
    private var sequenceCounter = 0
    @Volatile private var isListeningActive = false

    companion object {
        private const val TAG = "AndroidSpeechEngine"
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
        this.isListeningActive = true

        listener?.invoke(SpeechEvent.ListeningStarted)

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault())
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true) // Force Tensor G3 local NPU offline processing
        }

        recognizer?.startListening(intent)
        Log.i(TAG, "SpeechRecognizer started offline model.")
    }

    override fun stopListening() {
        if (isListeningActive) {
            isListeningActive = false
            try {
                recognizer?.stopListening()
            } catch (e: Exception) {
                Log.w(TAG, "stopListening ignored exception: ${e.message}")
            }
            listener?.invoke(SpeechEvent.ListeningStopped)
            Log.i(TAG, "SpeechRecognizer stopped.")
        }
    }

    override fun destroy() {
        recognizer?.destroy()
        recognizer = null
        listener = null
        isListeningActive = false
    }

    private fun setupRecognitionListener() {
        recognizer?.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {
                Log.d(TAG, "Ready for speech")
                listener?.invoke(SpeechEvent.ReadyForSpeech)
            }

            override fun onBeginningOfSpeech() {
                Log.d(TAG, "Beginning of speech")
                listener?.invoke(SpeechEvent.BeginningOfSpeech)
            }

            override fun onRmsChanged(rmsdB: Float) {}

            override fun onBufferReceived(buffer: ByteArray?) {}

            override fun onEndOfSpeech() {
                Log.d(TAG, "End of speech")
                listener?.invoke(SpeechEvent.EndOfSpeech)
            }

            override fun onError(error: Int) {
                if (!isListeningActive && error == SpeechRecognizer.ERROR_CLIENT) {
                    Log.d(TAG, "Ignoring redundant ERROR_CLIENT after recognition finished.")
                    return
                }
                isListeningActive = false
                val errorMsg = getErrorMessage(error)
                Log.e(TAG, "Speech recognition error: $errorMsg (code $error)")
                if (error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) {
                    listener?.invoke(SpeechEvent.Timeout)
                }
                listener?.invoke(SpeechEvent.Error(error, errorMsg))
            }

            override fun onResults(results: Bundle?) {
                isListeningActive = false
                val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val confidences = results?.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)
                if (!matches.isNullOrEmpty()) {
                    val text = matches[0]
                    val confidence = confidences?.getOrNull(0) ?: 1.0f
                    Log.i(TAG, "Final result: $text (Confidence: $confidence)")
                    listener?.invoke(SpeechEvent.FinalResult(text, confidence))
                }
            }

            override fun onPartialResults(partialResults: Bundle?) {
                val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                if (!matches.isNullOrEmpty()) {
                    val text = matches[0]
                    sequenceCounter++
                    Log.d(TAG, "Partial result #$sequenceCounter: $text")
                    listener?.invoke(SpeechEvent.PartialResult(text, sequenceCounter))
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
