package com.hermes.transport

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.IBinder
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
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startServerThread() {
        isRunning = true
        Thread {
            try {
                serverSocket = ServerSocket(PORT)
                Log.i(TAG, "ServerSocket listening on port $PORT...")

                while (isRunning) {
                    val socket = serverSocket?.accept() ?: break
                    Log.i(TAG, "Client connected from ${socket.inetAddress}")
                    handleClientConnection(socket)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Server socket exception: ${e.message}")
            }
        }.start()
    }

    private fun handleClientConnection(socket: Socket) {
        this.clientSocket = socket
        try {
            val reader = BufferedReader(InputStreamReader(socket.getInputStream()))
            this.writer = PrintWriter(socket.getOutputStream(), true)

            // Send initial connection heartbeat
            sendJson(JSONObject().apply {
                put("version", "1.0")
                put("type", "heartbeat")
                put("status", "ready")
                put("timestamp", System.currentTimeMillis())
            })

            var line: String?
            while (isRunning && reader.readLine().also { line = it } != null) {
                line?.let { parseIncomingCommand(it) }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Connection error: ${e.message}")
        } finally {
            closeClientSocket()
        }
    }

    private fun parseIncomingCommand(jsonStr: String) {
        try {
            val json = JSONObject(jsonStr)
            val type = json.optString("type")
            val command = json.optString("command")

            if (type == "command") {
                when (command) {
                    "start_listening" -> {
                        Log.i(TAG, "Command received: start_listening")
                        speechEngine?.startListening { event -> handleSpeechEvent(event) }
                    }
                    "stop_listening" -> {
                        Log.i(TAG, "Command received: stop_listening")
                        speechEngine?.stopListening()
                    }
                    "ping" -> {
                        sendJson(JSONObject().apply {
                            put("version", "1.0")
                            put("type", "heartbeat")
                            put("status", "ready")
                            put("timestamp", System.currentTimeMillis())
                        })
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
            SpeechEvent.SpeechStarted -> Log.d(TAG, "Speech event: Started")
            SpeechEvent.SpeechEnded -> Log.d(TAG, "Speech event: Ended")
        }
    }

    private fun sendJson(json: JSONObject) {
        try {
            val raw = json.toString()
            writer?.println(raw)
            Log.d(TAG, "Sent JSON: $raw")
        } catch (e: Exception) {
            Log.e(TAG, "Error sending JSON: ${e.message}")
        }
    }

    private fun getErrorCodeString(code: Int): String {
        return when (code) {
            7 -> "SPEECH_TIMEOUT"
            3 -> "AUDIO_RECORD_ERROR"
            5 -> "CLIENT_ERROR"
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
