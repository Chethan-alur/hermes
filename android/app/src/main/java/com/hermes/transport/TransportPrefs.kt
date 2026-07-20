package com.hermes.transport

import android.content.Context
import com.hermes.speech.AndroidSpeechEngine

/**
 * Which transport(s) the [TransportServerService] is allowed to serve on, persisted in the shared
 * [AndroidSpeechEngine.PREFS] file (the same SharedPreferences the online/offline toggle uses).
 *
 * These are a policy gate, not a per-connection filter: under WireGuard a network connection arrives
 * on the tunnel interface, so the carrier cannot be distinguished per-connection. The service instead
 * uses these flags together with live availability (see TransportServerService.reconcile) to decide
 * whether to hold a listening socket open at all — which is also the battery optimisation.
 *
 * All flags default to true so a fresh install preserves the historical "listen on every interface"
 * behaviour, now gated by whether the transport is actually available.
 */
object TransportPrefs {
    const val KEY_LISTEN_WIFI = "listen_wifi"
    const val KEY_LISTEN_MOBILE = "listen_mobile"
    const val KEY_LISTEN_USB = "listen_usb"

    data class Selection(val wifi: Boolean, val mobile: Boolean, val usb: Boolean) {
        val any: Boolean get() = wifi || mobile || usb
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(AndroidSpeechEngine.PREFS, Context.MODE_PRIVATE)

    fun read(context: Context): Selection {
        val p = prefs(context)
        return Selection(
            wifi = p.getBoolean(KEY_LISTEN_WIFI, true),
            mobile = p.getBoolean(KEY_LISTEN_MOBILE, true),
            usb = p.getBoolean(KEY_LISTEN_USB, true),
        )
    }
}
