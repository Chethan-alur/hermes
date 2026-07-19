package com.hermes

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.hermes.transport.TransportServerService

class MainActivity : AppCompatActivity() {

    private lateinit var statusTextView: TextView
    private lateinit var toggleButton: Button
    private var isServiceRunning = false

    companion object {
        private const val PERMISSION_REQUEST_CODE = 200
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate()
        setContentView(createSimpleLayout())

        statusTextView = findViewById(R.id.text_status)
        toggleButton = findViewById(R.id.btn_toggle_service)

        checkPermissions()

        toggleButton.setOnClickListener {
            if (isServiceRunning) {
                stopHermesService()
            } else {
                startHermesService()
            }
        }
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
        statusTextView.text = "Status: Service Running (Port 9999)"
        toggleButton.text = "Stop Hermes Companion Service"
    }

    private fun stopHermesService() {
        val intent = Intent(this, TransportServerService::class.java)
        stopService(intent)
        isServiceRunning = false
        statusTextView.text = "Status: Service Stopped"
        toggleButton.text = "Start Hermes Companion Service"
    }

    private fun createSimpleLayout(): android.view.View {
        val layout = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setPadding(48, 48, 48, 48)
            gravity = android.view.Gravity.CENTER
        }

        val title = TextView(this).apply {
            text = "Project Hermes Companion"
            textSize = 24f
            setTypeface(null, android.graphics.Typeface.BOLD)
            setPadding(0, 0, 0, 32)
        }

        val status = TextView(this).apply {
            id = R.id.text_status
            text = "Status: Service Stopped"
            textSize = 16f
            setPadding(0, 0, 0, 48)
        }

        val button = Button(this).apply {
            id = R.id.btn_toggle_service
            text = "Start Hermes Companion Service"
        }

        layout.addView(title)
        layout.addView(status)
        layout.addView(button)

        return layout
    }
}
