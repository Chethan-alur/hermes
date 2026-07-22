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

    // Reverse-connect (REQ-FUNC-018): the phone dials the Windows client instead of listening.
    // Needed where the network permits only outbound connections from the phone (e.g. a full-tunnel
    // corporate VPN with stateful client isolation, where laptop->phone inbound is impossible but
    // phone->laptop is not). When enabled with at least one target host, the service opens an
    // outbound socket to the PC and runs the same frame protocol.
    const val KEY_REVERSE_CONNECT = "reverse_connect"
    const val KEY_REVERSE_HOSTS = "reverse_hosts"
    const val KEY_REVERSE_PORT = "reverse_port"
    const val DEFAULT_REVERSE_PORT = 9999

    data class Selection(val wifi: Boolean, val mobile: Boolean, val usb: Boolean) {
        val any: Boolean get() = wifi || mobile || usb
    }

    /** Reverse-connect configuration. [enabled] gates the dial-out mode entirely. */
    data class Reverse(val enabled: Boolean, val hosts: List<String>, val port: Int) {
        val active: Boolean get() = enabled && hosts.isNotEmpty()
    }

    /**
     * Parse a free-form PC-host list (comma / space / semicolon / newline separated) into an ordered,
     * de-duplicated list of trimmed host tokens. Each token may carry an optional `:port` which is
     * preserved verbatim for the caller to split. Pure and framework-free so it is unit-testable
     * (mirrors `TransportServerService.nsdServiceName` / `isUsbTetherInterfaceName`). (REQ-FUNC-018)
     */
    fun parseReverseHosts(raw: String): List<String> =
        raw.split(',', ';', ' ', '\n', '\r', '\t')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()

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

    fun readReverse(context: Context): Reverse {
        val p = prefs(context)
        return Reverse(
            enabled = p.getBoolean(KEY_REVERSE_CONNECT, false),
            hosts = parseReverseHosts(p.getString(KEY_REVERSE_HOSTS, "") ?: ""),
            port = p.getInt(KEY_REVERSE_PORT, DEFAULT_REVERSE_PORT),
        )
    }
}
