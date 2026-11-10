package com.follow.clash.plugins

import java.net.InetAddress
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FreeV6NetworkStateTest {
    private fun state(address: String, wifi: Boolean = true, route: Boolean = true) =
        FreeV6NetworkState(wifi, listOf(InetAddress.getByName(address)), route)

    @Test
    fun `ULA behind an IPv6 forwarding router can prepare WARP`() {
        assertTrue(state("fdd6:82f6:9394::929").ready)
        assertTrue(state("fc00::1").ready)
        assertTrue(state("240e::1").ready)
        assertTrue(state("fec0::1").ready)
    }

    @Test
    fun `local-only and IPv4 addresses cannot reach IPv6 endpoints`() {
        for (address in listOf("fe80::1", "::1", "::", "ff02::1", "192.168.1.2", "::ffff:192.168.1.2")) {
            assertFalse(address, state(address).ready)
        }
    }

    @Test
    fun `an address alone does not replace Wi-Fi and an IPv6 route`() {
        assertFalse(state("fd12::1", wifi = false).ready)
        assertFalse(state("240e::1", route = false).ready)
        assertFalse(FreeV6NetworkState(true, emptyList(), true).ready)
    }
}
