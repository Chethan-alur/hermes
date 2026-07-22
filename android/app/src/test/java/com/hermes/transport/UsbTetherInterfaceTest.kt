package com.hermes.transport

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * REQ-FUNC-008 / REQ-FUNC-012 — USB-tether interface detection used by the availability gate; and
 * REQ-FUNC-016 — the mDNS/DNS-SD service name advertised for discovery. Pure logic, no runtime.
 */
class UsbTetherInterfaceTest {

    @Test
    fun matchesTetherInterfaceNames() {
        assertTrue(TransportServerService.isUsbTetherInterfaceName("ncm0"))
        assertTrue(TransportServerService.isUsbTetherInterfaceName("rndis0"))
        assertTrue(TransportServerService.isUsbTetherInterfaceName("usb0"))
    }

    @Test
    fun rejectsNonTetherInterfaces() {
        assertFalse(TransportServerService.isUsbTetherInterfaceName("wlan0"))
        assertFalse(TransportServerService.isUsbTetherInterfaceName("rmnet1"))
        assertFalse(TransportServerService.isUsbTetherInterfaceName("lo"))
        assertFalse(TransportServerService.isUsbTetherInterfaceName("eth0"))
    }

    @Test
    fun nsdServiceNamePrefixesModel() {
        assertEquals("Hermes (Pixel 8)", TransportServerService.nsdServiceName("Pixel 8"))
    }

    @Test
    fun nsdServiceNameStripsUnsafeChars() {
        assertEquals("Hermes (ab)", TransportServerService.nsdServiceName("a/b"))
    }

    @Test
    fun nsdServiceNameFallsBackWhenEmpty() {
        assertEquals("Hermes (device)", TransportServerService.nsdServiceName("   "))
    }
}
