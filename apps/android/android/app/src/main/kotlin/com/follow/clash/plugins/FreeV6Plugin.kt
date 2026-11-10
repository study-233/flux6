package com.follow.clash.plugins

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class FreeV6Plugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val executor = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dev.freev6.mobile/storage")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(
                KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build(),
            )
        }.generateKey()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val preferences = context.getSharedPreferences("freev6-secrets", Context.MODE_PRIVATE)
                when (call.method) {
                    "read" -> {
                        val record = preferences.getString("warp", null)
                        if (record == null) {
                            result.success(null)
                        } else {
                            val parts = record.split(":")
                            require(parts.size == 2)
                            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, decode(parts[0])))
                            result.success(String(cipher.doFinal(decode(parts[1])), Charsets.UTF_8))
                        }
                    }
                    "write" -> {
                        val value = call.arguments as? String ?: error("Invalid credentials")
                        require(value.length in 1..32768)
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                        cipher.init(Cipher.ENCRYPT_MODE, key())
                        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
                        check(preferences.edit().putString("warp", "${encode(cipher.iv)}:${encode(encrypted)}").commit())
                        result.success(null)
                    }
                    "network" -> {
                        val manager = context.getSystemService(ConnectivityManager::class.java)
                        val candidates = manager.allNetworks.filter { network ->
                            val caps = manager.getNetworkCapabilities(network)
                            caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true &&
                                !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                        }.map { network ->
                            val properties = manager.getLinkProperties(network)
                            network to FreeV6NetworkState(
                                wifi = true,
                                addresses = properties?.linkAddresses.orEmpty().map { it.address },
                                defaultRoute = properties?.routes.orEmpty().any {
                                    it.isDefaultRoute && it.destination.address is Inet6Address
                                },
                            )
                        }
                        val selected = candidates.firstOrNull()
                        val state = selected?.second ?: FreeV6NetworkState(false, emptyList(), false)
                        val report = state.toMap().toMutableMap()
                        if (call.argument<Boolean>("probe") == true && state.ready && selected != null) {
                            val probes = listOf("2001:da8:d800::1043", "2606:4700:4700::1111").map { host ->
                                val reachable = runCatching {
                                    selected.first.socketFactory.createSocket().use { socket ->
                                        socket.connect(InetSocketAddress(InetAddress.getByName(host), 443), 2500)
                                    }
                                }.isSuccess
                                mapOf("host" to host, "reachable" to reachable)
                            }
                            report["probes"] = probes
                            report["reachable"] = probes.any { it["reachable"] == true }
                        }
                        result.success(report)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("freev6_storage", "Flux6 secure storage or network check failed", null)
            }
        }
    }

    private fun encode(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)
    private fun decode(value: String): ByteArray = Base64.decode(value, Base64.NO_WRAP)

    companion object {
        private const val KEY_ALIAS = "dev.freev6.mobile.warp.v1"
    }
}
