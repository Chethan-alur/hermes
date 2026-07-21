package com.hermes.speech

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.mlkit.genai.common.DownloadCallback
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.proofreading.Proofreader
import com.google.mlkit.genai.proofreading.ProofreaderOptions
import com.google.mlkit.genai.proofreading.Proofreading
import com.google.mlkit.genai.proofreading.ProofreadingRequest
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean

/**
 * On-device transcript cleanup via Gemini Nano (ML Kit GenAI Proofreading). (REQ-FUNC-015)
 *
 * Corrects grammar and punctuation on the final dictation transcript before it is delivered.
 * Strictly best-effort: if the on-device model is unavailable, still downloading, times out, or
 * inference fails, [proofread] returns the original text unchanged so dictation never breaks. The
 * feature model is checked once at construction and downloaded on demand; correction only kicks in
 * once the model reports ready.
 */
class TranscriptProofreader(context: Context) {

    private val main = Handler(Looper.getMainLooper())
    // ML Kit GenAI returns Guava ListenableFutures; run their completion listeners on the main thread.
    private val mainExecutor = Executor { main.post(it) }

    private val proofreader: Proofreader? = try {
        Proofreading.getClient(
            ProofreaderOptions.builder(context)
                .setInputType(ProofreaderOptions.InputType.VOICE)
                .setLanguage(ProofreaderOptions.Language.ENGLISH)
                .build()
        )
    } catch (e: Throwable) {
        Log.w(TAG, "Proofreader client unavailable: ${e.message}")
        null
    }

    @Volatile private var ready = false

    init { refreshAvailability() }

    private fun refreshAvailability() {
        val pr = proofreader ?: return
        try {
            val f = pr.checkFeatureStatus()
            f.addListener({
                val status = try { f.get() } catch (e: Throwable) {
                    Log.w(TAG, "checkFeatureStatus failed: ${e.message}"); FeatureStatus.UNAVAILABLE
                }
                when (status) {
                    FeatureStatus.AVAILABLE -> ready = true
                    FeatureStatus.DOWNLOADABLE -> { ready = false; download(pr) }
                    else -> ready = false
                }
                Log.i(TAG, "Proofreading feature status=$status ready=$ready")
            }, mainExecutor)
        } catch (e: Throwable) {
            Log.w(TAG, "checkFeatureStatus threw: ${e.message}")
        }
    }

    private fun download(pr: Proofreader) {
        try {
            pr.downloadFeature(object : DownloadCallback {
                override fun onDownloadStarted(bytesToDownload: Long) {
                    Log.i(TAG, "Proofreading model download started ($bytesToDownload bytes).")
                }
                override fun onDownloadProgress(totalBytesDownloaded: Long) {}
                override fun onDownloadCompleted() { ready = true; Log.i(TAG, "Proofreading model ready.") }
                override fun onDownloadFailed(e: GenAiException) {
                    ready = false; Log.w(TAG, "Proofreading model download failed: ${e.message}")
                }
            })
        } catch (e: Throwable) {
            Log.w(TAG, "downloadFeature threw: ${e.message}")
        }
    }

    /**
     * Proofread [text] on-device, calling [onResult] exactly once on the main thread with the
     * corrected text -- or the original [text] on any failure, timeout, or unavailability.
     */
    fun proofread(text: String, timeoutMs: Long, onResult: (String) -> Unit) {
        val pr = proofreader
        if (pr == null || !ready || text.isBlank()) { onResult(text); return }

        val done = AtomicBoolean(false)
        val fallback = Runnable { if (done.compareAndSet(false, true)) onResult(text) }
        main.postDelayed(fallback, timeoutMs)
        val finish: (String) -> Unit = { out ->
            if (done.compareAndSet(false, true)) { main.removeCallbacks(fallback); onResult(out) }
        }

        try {
            val request = ProofreadingRequest.builder(text).build()
            val f = pr.runInference(request)
            f.addListener({
                val cleaned = try {
                    f.get().results.firstOrNull()?.text?.takeIf { it.isNotBlank() } ?: text
                } catch (e: Throwable) {
                    Log.w(TAG, "runInference failed: ${e.message}"); text
                }
                finish(cleaned)
            }, mainExecutor)
        } catch (e: Throwable) {
            Log.w(TAG, "runInference threw: ${e.message}"); finish(text)
        }
    }

    fun close() { try { proofreader?.close() } catch (_: Throwable) {} }

    companion object { private const val TAG = "TranscriptProofreader" }
}
