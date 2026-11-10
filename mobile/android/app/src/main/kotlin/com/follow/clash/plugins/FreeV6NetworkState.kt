package com.follow.clash.plugins

import java.net.Inet6Address
import java.net.InetAddress

internal data class FreeV6NetworkState(
    val wifi: Boolean,
    val addresses: List<InetAddress>,
    val defaultRoute: Boolean,
) {
    val hasAddress: Boolean
        get() = addresses.any {
            it is Inet6Address && !it.isLinkLocalAddress && !it.isLoopbackAddress &&
                !it.isAnyLocalAddress && !it.isMulticastAddress
        }

    val ready: Boolean get() = wifi && hasAddress && defaultRoute

    fun toMap(): Map<String, Any> = mapOf(
        "wifi" to wifi,
        "ipv6" to ready,
        "hasAddress" to hasAddress,
        "defaultRoute" to defaultRoute,
        "addresses" to addresses.filterIsInstance<Inet6Address>().mapNotNull { it.hostAddress },
    )
}
