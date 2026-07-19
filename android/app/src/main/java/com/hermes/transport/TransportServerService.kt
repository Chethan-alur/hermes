package com.hermes.transport

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
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
import java.net.ServerSocket
import java.net.Socket

class TransportServerService : Service() {
    private var serverSocket: ServerSocket? = null
    private var clientSocket: Socket? = null
    private var writer: PrintWriter? = null
    private var isRunning = false
    private var speechEngine: SpeechEngine? = null

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
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("Hermes Service Active (Port $PORT)"))

        speechEngine = AndroidSpeechEngine(this)
        startServerThread()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        stopServer()
        speechEngine?.destroy()
        speechEngine = null
        senderExecutor.shutdown()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startServerThread() {
        isRunning = true
        Thread {
            while (isRunning) {
                try {
                    if (serverSocket == null || serverSocket?.isClosed == true) {
                        serverSocket = ServerSocket(PORT).apply {
                            reuseAddress = true
                        }
                        Log.i(TAG, "ServerSocket listening on port $PORT...")
                    }

                    val socket = serverSocket?.accept() ?: break
                    Log.i(TAG, "Client connected from ${socket.inetAddress}")
                    Thread { handleClientConnection(socket) }.start()
                } catch (e: Exception) {
                    if (isRunning) {
                        Log.e(TAG, "Server socket exception: ${e.message}. Retrying accept in 1s...")
                        try { Thread.sleep(1000) } catch (_: Exception) {}
                    }
                }
            }
        }.start()
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
            while (isRunning && reader.readLine().also { line = it } != null) {
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
            Log.d(TAG, "📥 [TCP RECV RAW]: $jsonStr")
            val json = JSONObject(jsonStr)
            val type = json.optString("type")
            val command = json.optString("command")

            if (type == "command") {
                when (command) {
                    "start_listening" -> {
                        Log.i(TAG, "🔑 [HOTKEY COMMAND RECV]: 'start_listening' -> Dispatching to Main UI thread...")
                        mainHandler.post {
                            speechEngine?.startListening { event -> handleSpeechEvent(event) }
                        }
                    }
                    "stop_listening" -> {
                        Log.i(TAG, "🔑 [HOTKEY COMMAND RECV]: 'stop_listening' -> Dispatching to Main UI thread...")
                        mainHandler.post {
                            speechEngine?.stopListening()
                        }
                    }
                    "ping" -> {
                        Log.d(TAG, "💓 [HEARTBEAT RECV]: Responding with ready heartbeat...")
                        sendJson(JSONObject().apply {
                            put("version", "1.0")
                            put("type", "heartbeat")
                            put("status", "ready")
                            put("timestamp", System.currentTimeMillis())
                        })
                    }
                    "simulate_speech" -> {
                        Log.i(TAG, "🧪 [E2E MOCK SPEECH]: Simulating speech stream for automated E2E self-testing...")
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
                    else -> {
                        Log.w(TAG, "⚠️ Unknown command received: $command")
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

    private fun closeClientSocket() {
        try {
            clientSocket?.close()
        } catch (e: Exception) { }
        clientSocket = null
        writer = null
    }

    private fun stopServer() {
        closeClientSocket()
        try {
            serverSocket?.close()
        } catch (e: Exception) { }
        serverSocket = null
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
