package com.follow.clash.plugins

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
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
                    "clearLegacy" -> {
                        check(preferences.edit().clear().commit())
                        KeyStore.getInstance("AndroidKeyStore").apply {
                            load(null)
                            if (containsAlias(KEY_ALIAS)) deleteEntry(KEY_ALIAS)
                        }
                        result.success(null)
                    }
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
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("freev6_storage", "Flux6 secure storage failed", null)
            }
        }
    }

    private fun encode(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)
    private fun decode(value: String): ByteArray = Base64.decode(value, Base64.NO_WRAP)

    companion object {
        private const val KEY_ALIAS = "dev.freev6.mobile.warp.v1"
    }
}
