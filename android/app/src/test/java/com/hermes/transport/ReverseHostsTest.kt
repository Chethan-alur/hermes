package com.hermes.transport

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * REQ-FUNC-018 (`UT-AND-REVERSEHOSTS-001`) — the pure PC-host list parser used by reverse-connect.
 * The phone dials the Windows client, so the user-entered target list must be tolerant of the ways
 * people separate hosts (commas, spaces, semicolons, newlines) while staying ordered and de-duped.
 * Pure logic, no Android runtime.
 */
class ReverseHostsTest {

    @Test
    fun splitsOnCommaSpaceSemicolonAndNewline() {
        assertEquals(
            listOf("10.141.1.47", "10.10.0.10", "192.168.6.5", "hermes-pc"),
            TransportPrefs.parseReverseHosts("10.141.1.47, 10.10.0.10;192.168.6.5\nhermes-pc")
        )
    }

    @Test
    fun trimsAndDropsEmptyTokens() {
        assertEquals(
            listOf("10.141.1.47"),
            TransportPrefs.parseReverseHosts("  ,  10.141.1.47 ,, \t ")
        )
    }

    @Test
    fun deduplicatesPreservingFirstOrder() {
        assertEquals(
            listOf("10.141.1.47", "10.10.0.10"),
            TransportPrefs.parseReverseHosts("10.141.1.47 10.10.0.10 10.141.1.47")
        )
    }

    @Test
    fun emptyInputYieldsEmptyList() {
        assertEquals(emptyList<String>(), TransportPrefs.parseReverseHosts(""))
        assertEquals(emptyList<String>(), TransportPrefs.parseReverseHosts("   \n\t "))
    }

    @Test
    fun preservesExplicitPortToken() {
        // `host:port` tokens are kept verbatim; the service splits the port at dial time.
        assertEquals(
            listOf("10.141.1.47:9999", "10.10.0.10"),
            TransportPrefs.parseReverseHosts("10.141.1.47:9999, 10.10.0.10")
        )
    }
}
