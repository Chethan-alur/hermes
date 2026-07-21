package com.hermes.speech

import android.media.AudioDeviceInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * REQ-FUNC-013 — verifies the Bluetooth microphone selection policy used to route dictation
 * capture to a connected headset. Pure logic, no Android framework runtime needed.
 */
class BluetoothInputSelectionTest {

    @Test
    fun prefersLeAudioOverClassicSco() {
        val types = listOf(
            AudioDeviceInfo.TYPE_BUILTIN_MIC,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
        )
        assertEquals(
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AndroidSpeechEngine.preferredBluetoothInputType(types),
        )
    }

    @Test
    fun fallsBackToClassicScoWhenNoLeAudio() {
        val types = listOf(AudioDeviceInfo.TYPE_BUILTIN_MIC, AudioDeviceInfo.TYPE_BLUETOOTH_SCO)
        assertEquals(
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AndroidSpeechEngine.preferredBluetoothInputType(types),
        )
    }

    @Test
    fun returnsNullWhenNoBluetoothInput() {
        val types = listOf(AudioDeviceInfo.TYPE_BUILTIN_MIC, AudioDeviceInfo.TYPE_USB_DEVICE)
        assertNull(AndroidSpeechEngine.preferredBluetoothInputType(types))
    }

    @Test
    fun returnsNullForEmptyDeviceList() {
        assertNull(AndroidSpeechEngine.preferredBluetoothInputType(emptyList()))
    }
}
