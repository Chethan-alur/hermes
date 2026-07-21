package com.hermes.transport

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.IBinder
import android.speech.SpeechRecognizer
import android.util.Log
import com.hermes.speech.AndroidSpeechEngine
import com.hermes.speech.SpeechEngine
import com.hermes.speech.SpeechEvent
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.PrintWriter
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket

/**
 * TCP transport server for the Windows companion.
 *
 * The listener is **availability-gated**: it holds a bound [ServerSocket] open only while a
 * user-selected transport (Wi-Fi / mobile / USB tethering — see [TransportPrefs]) is actually
 * present, and closes it otherwise. This single rule both enforces the user's transport selection
 * and minimises battery: with nothing selected available, the service parks and consumes no radio
 * or CPU (no wake locks are ever held). See [reconcile].
 *
 * USB communication uses **USB tethering** (the phone's `usb0`/`rndis0`/`ncm0` interface), not ADB,
 * so the device's developer options can stay disabled.
 */
class TransportServerService : Service() {

    /** Where a listening socket should be bound, or `null` to not listen at all. */
    private sealed interface BindTarget {
        /** Bind the wildcard address `0.0.0.0` (covers the WireGuard `tun` and every interface). */
        object Wildcard : BindTarget
        /** Bind one specific address (used to confine USB-only serving to the `usb0` address). */
        data class Specific(val address: InetAddress) : BindTarget
    }

    // --- Serving state -----------------------------------------------------------
    @Volatile private var serviceAlive = false
    private var serverSocket: ServerSocket? = null
    private var serverThread: Thread? = null
    private var currentTarget: BindTarget? = null
    private var speechEngine: SpeechEngine? = null

    // --- Transport availability --------------------------------------------------
    private val networks = java.util.concurrent.ConcurrentHashMap<Network, NetworkCapabilities>()
    @Volatile private var wifiAvailable = false
    @Volatile private var cellularAvailable = false
    @Volatile private var usbTetherUp = false
    @Volatile private var usbAddress: InetAddress? = null

    // Socket writes must never run on the main/UI thread: SpeechRecognizer callbacks are
    // delivered on the main thread, and a blocking socket write there throws
    // NetworkOnMainThreadException (silently swallowed below), which is why real
    // partial/final/error results never reached the client. A single-thread executor keeps
    // writes off the main thread while preserving message ordering.
    private val senderExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()

    companion object {
        private const val TAG = "TransportServer"
        private const val PORT = 9999
        private const val CHANNEL_ID = "HermesTransportChannel"
        private const val NOTIFICATION_ID = 1001

        /** Ask a running service to re-read [TransportPrefs] and re-evaluate which sockets to hold. */
        const val ACTION_RECONFIGURE = "com.hermes.transport.action.RECONFIGURE"

        // USB cable/function state. This action is a sticky broadcast that is only ever delivered to
        // runtime-registered receivers, never to manifest-declared ones.
        private const val ACTION_USB_STATE = "android.hardware.usb.action.USB_STATE"

        /**
         * Whether [name] (already lower-cased) is a USB-tethering network interface
         * (RNDIS / NCM / usb*). Pure and framework-free so it is unit-testable. (REQ-FUNC-008)
         */
        internal fun isUsbTetherInterfaceName(name: String): Boolean =
            name.startsWith("usb") || name.startsWith("rndis") || name.startsWith("ncm")
    }

    override fun onCreate() {
        super.onCreate()
        serviceAlive = true
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("Starting…"))

        speechEngine = AndroidSpeechEngine(this)

        // Seed USB state synchronously; Wi-Fi/cellular arrive immediately via the network callback.
        refreshUsbState()
        registerNetworkCallback()
        registerUsbReceiver()
        reconcile()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_RECONFIGURE) {
            Log.i(TAG, "Reconfigure requested; re-evaluating transport selection.")
            reconcile()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        serviceAlive = false
        try {
            getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(networkCallback)
        } catch (_: Exception) {}
        try { unregisterReceiver(usbStateReceiver) } catch (_: Exception) {}
        stopServing()
        speechEngine?.destroy()
        speechEngine = null
        senderExecutor.shutdown()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // --- Availability tracking ---------------------------------------------------

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            networks[network] = caps
            recomputeTransportFlags()
            reconcile()
        }

        override fun onLost(network: Network) {
            networks.remove(network)
            recomputeTransportFlags()
            reconcile()
        }
    }

    private fun registerNetworkCallback() {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        // Match any INTERNET-capable Wi-Fi or cellular network. A WireGuard VPN network carries
        // TRANSPORT_VPN (not Wi-Fi/cellular) so it is intentionally excluded: we track the real
        // underlying carrier, and the physical Wi-Fi/cellular networks remain visible even when the
        // VPN is up.
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .build()
        try {
            cm.registerNetworkCallback(request, networkCallback)
        } catch (e: Exception) {
            Log.e(TAG, "registerNetworkCallback failed: ${e.message}")
        }
    }

    private fun recomputeTransportFlags() {
        wifiAvailable = networks.values.any { it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) }
        cellularAvailable = networks.values.any { it.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) }
    }

    private val usbStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != ACTION_USB_STATE) return
            // Re-enumerate on any USB state/function change (cable connect, tether toggle, …).
            refreshUsbState()
            Log.i(TAG, "USB_STATE change -> usbTetherUp=$usbTetherUp addr=${usbAddress?.hostAddress}")
            reconcile()
        }
    }

    private fun registerUsbReceiver() {
        // minSdk 34, so RECEIVER_NOT_EXPORTED is always available.
        registerReceiver(usbStateReceiver, IntentFilter(ACTION_USB_STATE), Context.RECEIVER_NOT_EXPORTED)
    }

    /** Detect an active USB-tethering interface and cache its IPv4 address. */
    private fun refreshUsbState() {
        usbAddress = detectUsbTetherAddress()
        usbTetherUp = usbAddress != null
    }

    private fun detectUsbTetherAddress(): InetAddress? {
        return try {
            NetworkInterface.getNetworkInterfaces()?.toList()?.firstNotNullOfOrNull { nif ->
                val name = nif.name?.lowercase() ?: return@firstNotNullOfOrNull null
                val looksUsb = isUsbTetherInterfaceName(name)
                if (!looksUsb || !nif.isUp) return@firstNotNullOfOrNull null
                nif.inetAddresses?.toList()?.firstOrNull { addr ->
                    addr is Inet4Address && !addr.isLoopbackAddress && addr.isSiteLocalAddress
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "USB interface enumeration failed: ${e.message}")
            null
        }
    }

    // --- Reconciliation: decide what (if anything) to listen on ------------------

    @Synchronized
    private fun reconcile() {
        // Re-detect the USB tether on every reconcile so a missed ACTION_USB_STATE broadcast can't
        // leave the listener stuck idle: the frequent, reliable Wi-Fi/cellular network callbacks
        // that also drive reconcile() then pick the tether back up on their own. (REQ-FUNC-012)
        refreshUsbState()
        val sel = TransportPrefs.read(this)
        val serveNetwork = (sel.wifi && wifiAvailable) || (sel.mobile && cellularAvailable)
        val usbAddr = usbAddress
        val serveUsb = sel.usb && usbTetherUp && usbAddr != null

        val desired: BindTarget? = when {
            // Network (possibly WireGuard tunnel) → bind wildcard so the tun interface is covered.
            serveNetwork -> BindTarget.Wildcard
            // USB tethering only → confine serving to the usb0 address (no exposure on Wi-Fi/cellular).
            serveUsb -> BindTarget.Specific(usbAddr!!)
            else -> null
        }

        if (applyBind(desired)) {
            Log.i(TAG, "reconcile: wifi=$wifiAvailable cell=$cellularAvailable usb=$usbTetherUp " +
                    "sel=[wifi=${sel.wifi} mobile=${sel.mobile} usb=${sel.usb}] -> ${describe(desired)}")
        }
        updateNotification()
    }

    /** Apply the desired bind target. Returns true if the serving state changed. */
    private fun applyBind(desired: BindTarget?): Boolean {
        if (desired == currentTarget) return false
        stopServing()
        // Latch currentTarget only on a successful bind, so a failed bind (e.g. the usb0 address
        // vanished mid-reconcile) is retried on the next signal rather than stuck.
        currentTarget = if (desired != null && !startServing(desired)) null else desired
        return true
    }

    private fun stopServing() {
        val sock = serverSocket
        serverSocket = null
        serverThread = null
        // Closing the socket unblocks the parked accept() and terminates its loop (socket.isClosed).
        try { sock?.close() } catch (_: Exception) {}
    }

    /** Open and start an accept loop for [target]. Returns true on success. */
    private fun startServing(target: BindTarget): Boolean {
        val bindAddr: InetAddress? = when (target) {
            BindTarget.Wildcard -> null                 // null => wildcard 0.0.0.0
            is BindTarget.Specific -> target.address
        }
        val socket = try {
            ServerSocket().apply {
                reuseAddress = true                     // must precede bind()
                bind(InetSocketAddress(bindAddr, PORT), 50)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to bind ${bindAddr?.hostAddress ?: "0.0.0.0"}:$PORT: ${e.message}")
            null
        } ?: return false

        serverSocket = socket
        val thread = Thread { acceptLoop(socket) }
        serverThread = thread
        thread.start()
        Log.i(TAG, "ServerSocket listening on ${bindAddr?.hostAddress ?: "0.0.0.0"}:$PORT")
        return true
    }

    private fun acceptLoop(socket: ServerSocket) {
        while (!socket.isClosed) {
            try {
                val client = socket.accept()
                Log.i(TAG, "Client connected from ${client.inetAddress}")
                Thread { handleClientConnection(client) }.start()
            } catch (e: Exception) {
                if (socket.isClosed) break   // normal shutdown on rebind/stop
                Log.e(TAG, "Server socket exception: ${e.message}. Retrying accept in 1s...")
                try { Thread.sleep(1000) } catch (_: Exception) {}
            }
        }
        Log.i(TAG, "Accept loop exited (${socket.localSocketAddress}).")
    }

    private val activeWriters = java.util.Collections.synchronizedList(mutableListOf<PrintWriter>())

    private fun handleClientConnection(socket: Socket) {
        var clientWriter: PrintWriter? = null
        try {
            val reader = BufferedReader(InputStreamReader(socket.getInputStream()))
            clientWriter = PrintWriter(socket.getOutputStream(), true)
            activeWriters.add(clientWriter)

            // Send initial connection heartbeat
            clientWriter.println(JSONObject().apply {
                put("version", "1.0")
                put("type", "heartbeat")
                put("status", "ready")
                put("timestamp", System.currentTimeMillis())
            }.toString())

            var line: String? = null
            while (serviceAlive && reader.readLine().also { line = it } != null) {
                line?.let { parseIncomingCommand(it) }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Connection error: ${e.message}")
        } finally {
            clientWriter?.let { activeWriters.remove(it) }
            try { socket.close() } catch (_: Exception) {}
        }
    }

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    private fun parseIncomingCommand(jsonStr: String) {
        try {
            val json = JSONObject(jsonStr)
            val type = json.optString("type")
            val command = json.optString("command")

            if (type == "command") {
                when (command) {
                    "start_listening" -> {
                        Log.i(TAG, "Command: start_listening")
                        mainHandler.post {
                            speechEngine?.startListening { event -> handleSpeechEvent(event) }
                        }
                    }
                    "stop_listening" -> {
                        Log.i(TAG, "Command: stop_listening")
                        mainHandler.post {
                            speechEngine?.stopListening()
                        }
                    }
                    "ping" -> {
                        Log.d(TAG, "Ping received; sending heartbeat")
                        sendJson(JSONObject().apply {
                            put("version", "1.0")
                            put("type", "heartbeat")
                            put("status", "ready")
                            put("timestamp", System.currentTimeMillis())
                        })
                    }
                    "simulate_speech" -> {
                        Log.i(TAG, "Simulating speech stream (E2E self-test)")
                        Thread {
                            try {
                                val mockText = json.optString("mock_text", "Project Hermes automated speech synthesis end to end test")
                                handleSpeechEvent(SpeechEvent.PartialResult(mockText, 1))
                                Thread.sleep(50)
                                handleSpeechEvent(SpeechEvent.FinalResult(mockText, 0.99f))
                            } catch (e: Exception) {
                                Log.e(TAG, "Mock speech simulation error: ${e.message}")
                            }
                        }.start()
                    }
                    "set_mic" -> {
                        val mic = json.optString("mic", "auto")
                        getSharedPreferences(AndroidSpeechEngine.PREFS, Context.MODE_PRIVATE)
                            .edit().putString(AndroidSpeechEngine.KEY_MIC_PREF, mic).apply()
                        Log.i(TAG, "Mic preference set to '$mic' (applies to the next dictation).")
                    }
                    else -> {
                        Log.w(TAG, "Unknown command: $command")
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse incoming command: $jsonStr - Error: ${e.message}")
        }
    }

    private fun handleSpeechEvent(event: SpeechEvent) {
        when (event) {
            is SpeechEvent.PartialResult -> {
                sendJson(JSONObject().apply {
                    put("version", "1.0")
                    put("type", "partial")
                    put("text", event.text)
                    put("sequence", event.sequence)
                    put("timestamp", System.currentTimeMillis())
                })
            }
            is SpeechEvent.FinalResult -> {
                sendJson(JSONObject().apply {
                    put("version", "1.0")
                    put("type", "final")
                    put("text", event.text)
                    put("confidence", event.confidence.toDouble())
                    put("timestamp", System.currentTimeMillis())
                })
            }
            is SpeechEvent.Error -> {
                sendJson(JSONObject().apply {
                    put("version", "1.0")
                    put("type", "error")
                    put("code", getErrorCodeString(event.code))
                    put("message", event.message)
                    put("timestamp", System.currentTimeMillis())
                })
            }
            is SpeechEvent.Status -> {
                sendJson(JSONObject().apply {
                    put("version", "1.0")
                    put("type", "status")
                    put("event", event.event)
                    event.mic?.let { put("mic", it) }
                    event.device?.let { put("device", it) }
                    event.detail?.let { put("detail", it) }
                    put("timestamp", System.currentTimeMillis())
                })
            }
            else -> Log.d(TAG, "Speech event: $event")
        }
    }

    private fun sendJson(json: JSONObject) {
        val raw = json.toString()
        // Dispatch the actual socket write off the caller's thread (see senderExecutor note).
        senderExecutor.execute {
            synchronized(activeWriters) {
                val iterator = activeWriters.iterator()
                while (iterator.hasNext()) {
                    val writer = iterator.next()
                    try {
                        writer.println(raw)
                        if (writer.checkError()) {
                            Log.w(TAG, "Client writer reported error; removing it.")
                            iterator.remove()
                        } else {
                            Log.d(TAG, "Broadcast JSON to client: $raw")
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "sendJson write failed, removing client writer: ${e.message}")
                        iterator.remove()
                    }
                }
            }
        }
    }

    private fun getErrorCodeString(code: Int): String {
        return when (code) {
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "NETWORK_TIMEOUT"
            SpeechRecognizer.ERROR_NETWORK -> "NETWORK_ERROR"
            SpeechRecognizer.ERROR_AUDIO -> "AUDIO_RECORD_ERROR"
            SpeechRecognizer.ERROR_SERVER -> "SERVER_ERROR"
            SpeechRecognizer.ERROR_CLIENT -> "CLIENT_ERROR"
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "SPEECH_TIMEOUT"
            SpeechRecognizer.ERROR_NO_MATCH -> "NO_MATCH"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "RECOGNIZER_BUSY"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "INSUFFICIENT_PERMISSIONS"
            else -> "UNKNOWN_ERROR"
        }
    }

    // --- Notification ------------------------------------------------------------

    private fun describe(target: BindTarget?): String = when (target) {
        null -> "idle (no selected transport available)"
        BindTarget.Wildcard -> "listening on 0.0.0.0:$PORT"
        is BindTarget.Specific -> "listening on USB ${target.address.hostAddress}:$PORT"
    }

    private fun currentServingText(): String = when (val t = currentTarget) {
        null -> "Idle — no selected transport available"
        BindTarget.Wildcard -> "Listening on port $PORT (selected transports)"
        is BindTarget.Specific -> "Listening on USB ${t.address.hostAddress}:$PORT"
    }

    private fun updateNotification() {
        getSystemService(NotificationManager::class.java)
            ?.notify(NOTIFICATION_ID, buildNotification(currentServingText()))
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Hermes Service Channel",
            NotificationManager.IMPORTANCE_LOW
        )
        val manager = getSystemService(NotificationManager::class.java)
        manager?.createNotificationChannel(channel)
    }

    private fun buildNotification(contentText: String): Notification {
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Project Hermes Companion")
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .build()
    }
}
