package com.hermes.transport

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * REQ-FUNC-008 / REQ-FUNC-012 — verifies which network-interface names are recognised as USB
 * tethering, used by the availability gate (and re-checked on every reconcile so a missed
 * ACTION_USB_STATE broadcast cannot strand the listener). Pure logic, no Android runtime needed.
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
}
