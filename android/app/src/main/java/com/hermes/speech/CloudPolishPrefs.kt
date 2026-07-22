package com.hermes.speech

import android.content.Context

/**
 * Cloud transcript-polishing configuration (REQ-FUNC-019), persisted in the shared
 * [AndroidSpeechEngine.PREFS] file (the same SharedPreferences the other toggles use).
 *
 * Off by default: cloud polish is the sole exception to the offline posture, so it activates only
 * when the user both enables the switch AND supplies their own API key ([Settings.active]) — a
 * toggled-on switch with no key is harmless. The key is app-private and must never be logged.
 */
object CloudPolishPrefs {
    const val KEY_ENABLED = "cloud_polish"
    const val KEY_API_KEY = "cloud_polish_api_key"
    const val KEY_MODEL = "cloud_polish_model"

    data class Settings(val enabled: Boolean, val apiKey: String, val model: String) {
        val active: Boolean get() = enabled && apiKey.isNotBlank()
    }

    /** Blank model falls back to [GeminiApi.DEFAULT_MODEL]. Read per final so UI edits apply live. */
    fun read(context: Context): Settings {
        val p = context.getSharedPreferences(AndroidSpeechEngine.PREFS, Context.MODE_PRIVATE)
        return Settings(
            enabled = p.getBoolean(KEY_ENABLED, false),
            apiKey = (p.getString(KEY_API_KEY, "") ?: "").trim(),
            model = (p.getString(KEY_MODEL, "") ?: "").trim().ifEmpty { GeminiApi.DEFAULT_MODEL },
        )
    }
}
