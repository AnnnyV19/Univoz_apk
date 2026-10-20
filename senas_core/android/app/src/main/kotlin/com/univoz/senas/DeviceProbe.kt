package com.univoz.senas

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.PowerManager

/**
 * Lo que DeviceTier necesita saber del telefono. Cualquier fallo devuelve un
 * valor neutro: RAM -1 (DeviceTier.nivelInicial -> medio), termico null.
 */
class DeviceProbe(private val context: Context) {
    fun ramMb(): Long = try {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        info.totalMem / (1024 * 1024)
    } catch (e: Exception) {
        -1
    }

    fun termico(): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            (context.getSystemService(Context.POWER_SERVICE) as PowerManager).currentThermalStatus
        } catch (e: Exception) {
            null
        }
    }
}
