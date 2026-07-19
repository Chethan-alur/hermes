package com.hermes

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.os.Bundle
import android.widget.ImageView
import android.widget.ScrollView
import android.widget.TextView
import androidx.annotation.ColorRes
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.android.material.button.MaterialButton
import com.google.android.material.materialswitch.MaterialSwitch
import com.hermes.speech.AndroidSpeechEngine
import com.hermes.speech.SpeechEngine
import com.hermes.speech.SpeechEvent
import com.hermes.transport.TransportServerService
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : AppCompatActivity() {

    private lateinit var statusText: TextView
    private lateinit var statusIcon: ImageView
    private lateinit var consoleText: TextView
    private lateinit var scrollConsole: ScrollView
    private var speechEngine: SpeechEngine? = null
    private val dateFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.getDefault())

    companion object {
        private const val PERMISSION_REQUEST_CODE = 200
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        statusText = findViewById(R.id.text_status)
        statusIcon = findViewById(R.id.status_icon)
        consoleText = findViewById(R.id.text_console)
        scrollConsole = findViewById(R.id.scroll_console)

        findViewById<MaterialButton>(R.id.btn_start_service).setOnClickListener { startHermesService() }
        findViewById<MaterialButton>(R.id.btn_stop_service).setOnClickListener { stopHermesService() }
        findViewById<MaterialButton>(R.id.btn_start_recognition).setOnClickListener { startRecognition() }
        findViewById<MaterialButton>(R.id.btn_stop_recognition).setOnClickListener { stopRecognition() }
        findViewById<MaterialButton>(R.id.btn_clear_log).setOnClickListener { clearLog() }

        // Offline (private) vs online (higher accuracy) recognition toggle.
        val prefs = getSharedPreferences(AndroidSpeechEngine.PREFS, MODE_PRIVATE)
        val switchOnline = findViewById<MaterialSwitch>(R.id.switch_online)
        switchOnline.isChecked = !prefs.getBoolean(AndroidSpeechEngine.KEY_PREFER_OFFLINE, true)
        switchOnline.setOnCheckedChangeListener { _, isChecked ->
            prefs.edit().putBoolean(AndroidSpeechEngine.KEY_PREFER_OFFLINE, !isChecked).apply()
            logEvent(if (isChecked) "Recognition mode: ONLINE (higher accuracy)" else "Recognition mode: OFFLINE (private)")
        }

        checkPermissions()
        speechEngine = AndroidSpeechEngine(this)
        startHermesService()
        setStatus("READY", R.color.status_ready)
        logEvent("System initialised. Foreground transport service started on port 9999.")
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
        setStatus("READY", R.color.status_ready)
        logEvent("Foreground service started.")
    }

    private fun stopHermesService() {
        val intent = Intent(this, TransportServerService::class.java)
        stopService(intent)
        setStatus("STOPPED", R.color.status_listening)
        logEvent("Foreground service stopped.")
    }

    private fun startRecognition() {
        setStatus("LISTENING", R.color.status_listening)
        logEvent("Manual start recognition triggered.")
        speechEngine?.startListening { event -> handleSpeechEvent(event) }
    }

    private fun stopRecognition() {
        setStatus("FINALIZING", R.color.status_recognizing)
        logEvent("Manual stop recognition triggered.")
        speechEngine?.stopListening()
    }

    private fun handleSpeechEvent(event: SpeechEvent) {
        runOnUiThread {
            when (event) {
                SpeechEvent.ListeningStarted -> {
                    setStatus("LISTENING", R.color.status_listening)
                    logEvent("ListeningStarted")
                }
                SpeechEvent.ListeningStopped -> {
                    setStatus("READY", R.color.status_ready)
                    logEvent("ListeningStopped")
                }
                SpeechEvent.ReadyForSpeech -> logEvent("ReadyForSpeech")
                SpeechEvent.BeginningOfSpeech -> {
                    setStatus("RECOGNIZING", R.color.status_recognizing)
                    logEvent("BeginningOfSpeech")
                }
                SpeechEvent.EndOfSpeech -> {
                    setStatus("FINALIZING", R.color.status_recognizing)
                    logEvent("EndOfSpeech")
                }
                SpeechEvent.Timeout -> {
                    setStatus("READY", R.color.status_ready)
                    logEvent("Timeout: no speech detected")
                }
                is SpeechEvent.PartialResult ->
                    logEvent("Partial: \"${event.text}\" (Seq #${event.sequence})")
                is SpeechEvent.FinalResult -> {
                    setStatus("READY", R.color.status_ready)
                    logEvent("Final: \"${event.text}\" (Conf: ${event.confidence})")
                }
                is SpeechEvent.Error -> {
                    setStatus("ERROR", R.color.status_listening)
                    logEvent("Error #${event.code}: ${event.message}")
                }
            }
        }
    }

    private fun setStatus(text: String, @ColorRes colorRes: Int) {
        val color = ContextCompat.getColor(this, colorRes)
        statusText.text = text
        statusText.setTextColor(color)
        statusIcon.imageTintList = ColorStateList.valueOf(color)
    }

    private fun logEvent(message: String) {
        val timestamp = dateFormat.format(Date())
        consoleText.append("$timestamp  $message\n")
        scrollConsole.post { scrollConsole.fullScroll(ScrollView.FOCUS_DOWN) }
    }

    private fun clearLog() {
        consoleText.text = ""
        logEvent("Console cleared.")
    }
}
