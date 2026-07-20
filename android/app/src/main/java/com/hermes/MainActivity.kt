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
import com.hermes.transport.TransportPrefs
import com.hermes.transport.TransportServerService
import java.net.Inet4Address
import java.net.NetworkInterface
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : AppCompatActivity() {

    private lateinit var statusText: TextView
    private lateinit var statusIcon: ImageView
    private lateinit var consoleText: TextView
    private lateinit var scrollConsole: ScrollView
    private lateinit var textPort: TextView
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
        textPort = findViewById(R.id.text_port)

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

        // Transport selection: which underlying transport(s) the service is allowed to listen on.
        val switchWifi = findViewById<MaterialSwitch>(R.id.switch_wifi)
        val switchMobile = findViewById<MaterialSwitch>(R.id.switch_mobile)
        val switchUsb = findViewById<MaterialSwitch>(R.id.switch_usb)
        switchWifi.isChecked = prefs.getBoolean(TransportPrefs.KEY_LISTEN_WIFI, true)
        switchMobile.isChecked = prefs.getBoolean(TransportPrefs.KEY_LISTEN_MOBILE, true)
        switchUsb.isChecked = prefs.getBoolean(TransportPrefs.KEY_LISTEN_USB, true)
        switchWifi.setOnCheckedChangeListener { _, c -> onTransportToggle(TransportPrefs.KEY_LISTEN_WIFI, c, "Wi-Fi") }
        switchMobile.setOnCheckedChangeListener { _, c -> onTransportToggle(TransportPrefs.KEY_LISTEN_MOBILE, c, "Mobile data") }
        switchUsb.setOnCheckedChangeListener { _, c -> onTransportToggle(TransportPrefs.KEY_LISTEN_USB, c, "USB tethering") }

        checkPermissions()
        speechEngine = AndroidSpeechEngine(this)
        startHermesService()
        setStatus("READY", R.color.status_ready)
        logEvent("System initialised. Foreground transport service started on port 9999.")
        refreshServingAddresses()
    }

    override fun onResume() {
        super.onResume()
        // The set of serving addresses (USB tether, Wi-Fi, WireGuard) can change while away.
        refreshServingAddresses()
    }

    override fun onDestroy() {
        speechEngine?.destroy()
        speechEngine = null
        super.onDestroy()
    }

    /** Persist a transport toggle and ask the running service to re-evaluate its listener. */
    private fun onTransportToggle(key: String, enabled: Boolean, label: String) {
        getSharedPreferences(AndroidSpeechEngine.PREFS, MODE_PRIVATE)
            .edit().putBoolean(key, enabled).apply()
        logEvent("Transport $label: ${if (enabled) "ENABLED" else "disabled"}")
        reconfigureService()
        refreshServingAddresses()
    }

    private fun reconfigureService() {
        val intent = Intent(this, TransportServerService::class.java).apply {
            action = TransportServerService.ACTION_RECONFIGURE
        }
        ContextCompat.startForegroundService(this, intent)
    }

    /** List the current non-loopback IPv4 addresses so the user can point the desktop client here. */
    private fun refreshServingAddresses() {
        val lines = mutableListOf<String>()
        try {
            for (nif in NetworkInterface.getNetworkInterfaces()) {
                if (!nif.isUp || nif.isLoopback) continue
                val ipv4 = nif.inetAddresses.toList()
                    .filterIsInstance<Inet4Address>()
                    .firstOrNull { !it.isLoopbackAddress }
                    ?.hostAddress ?: continue
                val name = nif.name.lowercase()
                val label = when {
                    name.startsWith("usb") || name.startsWith("rndis") || name.startsWith("ncm") -> "USB"
                    name.startsWith("wlan") -> "Wi-Fi"
                    name.startsWith("tun") || name.startsWith("wg") -> "WireGuard"
                    name.startsWith("rmnet") || name.startsWith("ccmni") -> "Mobile"
                    else -> nif.name
                }
                lines.add("$label  $ipv4:9999")
            }
        } catch (_: Exception) {}
        textPort.text = if (lines.isEmpty()) getString(R.string.serving_none) else lines.joinToString("\n")
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
