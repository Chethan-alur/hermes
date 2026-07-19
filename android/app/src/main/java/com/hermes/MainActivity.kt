package com.hermes

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.Button
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.hermes.speech.AndroidSpeechEngine
import com.hermes.speech.SpeechEngine
import com.hermes.speech.SpeechEvent
import com.hermes.transport.TransportServerService
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : AppCompatActivity() {

    private lateinit var statusTextView: TextView
    private lateinit var consoleTextView: TextView
    private lateinit var scrollView: ScrollView
    private var isServiceRunning = false
    private var speechEngine: SpeechEngine? = null
    private val dateFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.getDefault())

    companion object {
        private const val PERMISSION_REQUEST_CODE = 200
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(createFeasibilityLayout())

        statusTextView = findViewById(R.id.text_status)
        consoleTextView = findViewById(R.id.text_console)
        scrollView = findViewById(R.id.scroll_console)

        findViewById<Button>(R.id.btn_start_service).setOnClickListener { startHermesService() }
        findViewById<Button>(R.id.btn_stop_service).setOnClickListener { stopHermesService() }
        findViewById<Button>(R.id.btn_start_recognition).setOnClickListener { startRecognition() }
        findViewById<Button>(R.id.btn_stop_recognition).setOnClickListener { stopRecognition() }
        findViewById<Button>(R.id.btn_clear_log).setOnClickListener { clearLog() }

        checkPermissions()
        speechEngine = AndroidSpeechEngine(this)
        startHermesService()
        logEvent("System initialized. Hermes Foreground Transport Service Started on Port 9999.")
    }

    override fun onDestroy() {
        speechEngine?.destroy()
        speechEngine = null
        super.onDestroy()
    }

    private fun checkPermissions() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                PERMISSION_REQUEST_CODE
            )
        }
    }

    private fun startHermesService() {
        val intent = Intent(this, TransportServerService::class.java)
        ContextCompat.startForegroundService(this, intent)
        isServiceRunning = true
        statusTextView.text = "Status: SERVICE_STARTED (Port 9999)"
        logEvent("Foreground Service Started.")
    }

    private fun stopHermesService() {
        val intent = Intent(this, TransportServerService::class.java)
        stopService(intent)
        isServiceRunning = false
        statusTextView.text = "Status: STOPPED"
        logEvent("Foreground Service Stopped.")
    }

    private fun startRecognition() {
        statusTextView.text = "Status: LISTENING"
        logEvent("Manual Start Recognition Triggered.")
        speechEngine?.startListening { event -> handleSpeechEvent(event) }
    }

    private fun stopRecognition() {
        statusTextView.text = "Status: FINALIZING"
        logEvent("Manual Stop Recognition Triggered.")
        speechEngine?.stopListening()
    }

    private fun handleSpeechEvent(event: SpeechEvent) {
        runOnUiThread {
            when (event) {
                SpeechEvent.ListeningStarted -> {
                    statusTextView.text = "Status: LISTENING"
                    logEvent("ListeningStarted")
                }
                SpeechEvent.ListeningStopped -> {
                    statusTextView.text = "Status: READY"
                    logEvent("ListeningStopped")
                }
                SpeechEvent.ReadyForSpeech -> {
                    logEvent("ReadyForSpeech")
                }
                SpeechEvent.BeginningOfSpeech -> {
                    statusTextView.text = "Status: RECOGNIZING"
                    logEvent("BeginningOfSpeech")
                }
                SpeechEvent.EndOfSpeech -> {
                    statusTextView.text = "Status: FINALIZING"
                    logEvent("EndOfSpeech")
                }
                SpeechEvent.Timeout -> {
                    statusTextView.text = "Status: READY"
                    logEvent("Timeout: No speech detected")
                }
                is SpeechEvent.PartialResult -> {
                    logEvent("Partial: \"${event.text}\" (Seq #${event.sequence})")
                }
                is SpeechEvent.FinalResult -> {
                    statusTextView.text = "Status: READY"
                    logEvent("Final: \"${event.text}\" (Conf: ${event.confidence})")
                }
                is SpeechEvent.Error -> {
                    statusTextView.text = "Status: READY (Error)"
                    logEvent("Error #${event.code}: ${event.message}")
                }
            }
        }
    }

    private fun logEvent(message: String) {
        val timestamp = dateFormat.format(Date())
        val logLine = "$timestamp - $message\n"
        consoleTextView.append(logLine)
        scrollView.post { scrollView.fullScroll(ScrollView.FOCUS_DOWN) }
    }

    private fun clearLog() {
        consoleTextView.text = ""
        logEvent("Console log cleared.")
    }

    private fun createFeasibilityLayout(): android.view.View {
        val mainLayout = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setPadding(32, 32, 32, 32)
        }

        val title = TextView(this).apply {
            text = "Hermes Feasibility Test (Milestone 0)"
            textSize = 20f
            setTypeface(null, android.graphics.Typeface.BOLD)
            setPadding(0, 0, 0, 16)
        }

        val status = TextView(this).apply {
            id = R.id.text_status
            text = "Status: READY"
            textSize = 16f
            setTypeface(null, android.graphics.Typeface.BOLD)
            setPadding(0, 0, 0, 24)
        }

        val grid = android.widget.GridLayout(this).apply {
            columnCount = 2
            setPadding(0, 0, 0, 24)
        }

        val btnStartSvc = Button(this).apply { id = R.id.btn_start_service; text = "Start Service" }
        val btnStopSvc = Button(this).apply { id = R.id.btn_stop_service; text = "Stop Service" }
        val btnStartRec = Button(this).apply { id = R.id.btn_start_recognition; text = "Start Recognition" }
        val btnStopRec = Button(this).apply { id = R.id.btn_stop_recognition; text = "Stop Recognition" }

        grid.addView(btnStartSvc)
        grid.addView(btnStopSvc)
        grid.addView(btnStartRec)
        grid.addView(btnStopRec)

        val btnClear = Button(this).apply { id = R.id.btn_clear_log; text = "Clear Console Log" }

        val scroll = ScrollView(this).apply {
            id = R.id.scroll_console
            setBackgroundColor(0xFF1E1E1E.toInt())
            setPadding(16, 16, 16, 16)
            layoutParams = android.widget.LinearLayout.LayoutParams(
                android.widget.LinearLayout.LayoutParams.MATCH_PARENT,
                0,
                1.0f
            )
        }

        val console = TextView(this).apply {
            id = R.id.text_console
            setTextColor(0xFF00FF00.toInt()) // Matrix green console text
            textSize = 13f
            typeface = android.graphics.Typeface.MONOSPACE
        }

        scroll.addView(console)

        mainLayout.addView(title)
        mainLayout.addView(status)
        mainLayout.addView(grid)
        mainLayout.addView(btnClear)
        mainLayout.addView(scroll)

        return mainLayout
    }
}
