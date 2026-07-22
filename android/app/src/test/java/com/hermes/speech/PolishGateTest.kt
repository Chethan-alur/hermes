package com.hermes.speech

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * UT-AND-POLISH-002 (REQ-FUNC-019) — free-tier pacing gate and polisher-selection policy.
 * The clock is injected as plain milliseconds so no Android runtime is needed.
 */
class PolishGateTest {

    @Test
    fun firstAcquireAllowed() {
        val gate = RateGate(4000)
        assertTrue(gate.tryAcquire(nowMs = 10_000))
    }

    @Test
    fun withinMinIntervalRefused() {
        val gate = RateGate(4000)
        assertTrue(gate.tryAcquire(10_000))
        assertFalse(gate.tryAcquire(13_999))
        assertTrue(gate.tryAcquire(14_000))
    }

    @Test
    fun refusedAttemptDoesNotResetTheWindow() {
        val gate = RateGate(4000)
        assertTrue(gate.tryAcquire(10_000))
        assertFalse(gate.tryAcquire(11_000))
        // 4 s after the GRANTED call, not after the refused attempt.
        assertTrue(gate.tryAcquire(14_000))
    }

    @Test
    fun penaltyOpensCooldownWindow() {
        val gate = RateGate(4000)
        assertTrue(gate.tryAcquire(10_000))
        gate.penalize(10_500, penaltyMs = 60_000)
        assertTrue(gate.inCooldown(30_000))
        assertFalse(gate.tryAcquire(30_000))
        assertFalse(gate.tryAcquire(70_499))
        assertFalse(gate.inCooldown(70_500))
        assertTrue(gate.tryAcquire(70_500))
    }

    @Test
    fun cloudTakesPrecedenceWhenActive() {
        assertEquals(
            PolisherChoice.CLOUD,
            AndroidSpeechEngine.selectPolisher(cloudActive = true, onDeviceEnabled = true)
        )
        assertEquals(
            PolisherChoice.CLOUD,
            AndroidSpeechEngine.selectPolisher(cloudActive = true, onDeviceEnabled = false)
        )
    }

    @Test
    fun onDeviceWhenCloudInactive() {
        assertEquals(
            PolisherChoice.ON_DEVICE,
            AndroidSpeechEngine.selectPolisher(cloudActive = false, onDeviceEnabled = true)
        )
    }

    @Test
    fun rawWhenNothingEnabled() {
        assertEquals(
            PolisherChoice.NONE,
            AndroidSpeechEngine.selectPolisher(cloudActive = false, onDeviceEnabled = false)
        )
    }
}
