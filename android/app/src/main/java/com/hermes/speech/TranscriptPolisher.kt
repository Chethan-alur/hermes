package com.hermes.speech

/**
 * Best-effort post-processing of a final dictation transcript (grammar/punctuation) before it is
 * delivered. Vendor-neutral: implementations may run on-device ([TranscriptProofreader], Gemini
 * Nano, REQ-FUNC-015) or call a cloud AI vendor with the user's own key ([GeminiPolisher],
 * REQ-FUNC-019); future vendors (OpenAI, Anthropic, ...) implement the same interface.
 *
 * Contract: [polish] invokes [onResult] EXACTLY ONCE on the main thread, with the polished text —
 * or the original text unchanged on any failure, timeout, rate-limit, or unavailability. Dictation
 * must never break or stall on a polisher.
 */
interface TranscriptPolisher {
    fun polish(text: String, timeoutMs: Long, onResult: (String) -> Unit)

    /** Release held resources; the instance is unusable afterwards. */
    fun close()
}

/** Which polisher [AndroidSpeechEngine] should use for a final transcript. (REQ-FUNC-019) */
internal enum class PolisherChoice { CLOUD, ON_DEVICE, NONE }
