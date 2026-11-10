package com.follow.clash

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/** PackageManager persists the enabled launcher alias across app and device restarts. */
internal class LauncherIcons(private val context: Context) {
    private val aliases = linkedMapOf(
        "cow" to "Cow", "orange" to "Orange", "prism" to "Prism",
        "four-color" to "FourColor", "earth" to "Earth",
    )
    private fun component(id: String) = ComponentName(
        context.packageName, "com.follow.clash.Launcher" + aliases.getValue(id),
    )
    private fun enabled(id: String): Boolean = when (
        context.packageManager.getComponentEnabledSetting(component(id))
    ) {
        PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
        PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> id == "cow"
        else -> false
    }
    fun selected(): String = aliases.keys.firstOrNull(::enabled) ?: "cow"

    fun select(id: String): String {
        require(aliases.containsKey(id)) { "Unknown app icon" }
        val manager = context.packageManager
        val previous = aliases.keys.associateWith { manager.getComponentEnabledSetting(component(it)) }
        fun state(key: String) = if (key == id) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            else PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        if (Build.VERSION.SDK_INT >= 33) {
            manager.setComponentEnabledSettings(aliases.keys.map {
                PackageManager.ComponentEnabledSetting(component(it), state(it), PackageManager.DONT_KILL_APP)
            })
        } else {
            try {
                // Always create the replacement entry before hiding the previous entry.
                manager.setComponentEnabledSetting(component(id), state(id), PackageManager.DONT_KILL_APP)
                aliases.keys.filter { it != id }.forEach {
                    manager.setComponentEnabledSetting(component(it), state(it), PackageManager.DONT_KILL_APP)
                }
            } catch (error: Exception) {
                previous.forEach { (key, value) ->
                    runCatching { manager.setComponentEnabledSetting(component(key), value, PackageManager.DONT_KILL_APP) }
                }
                throw error
            }
        }
        return id
    }
}
