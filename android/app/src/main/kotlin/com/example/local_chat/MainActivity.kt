package com.example.local_chat

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "local_chat/app_control",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "moveTaskToBack" -> {
                    moveTaskToBack(true)
                    result.success(null)
                }
                "isIgnoringBatteryOptimizations" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    } else {
                        result.success(true)
                    }
                }
                "requestIgnoreBatteryOptimizations" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        try {
                            val intent =
                                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                    data = Uri.parse("package:$packageName")
                                }
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("BATTERY", e.message, null)
                        }
                    } else {
                        result.success(null)
                    }
                }
                "openApplicationDetailsSettings" -> {
                    try {
                        val intent =
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                            }
                        startActivity(intent)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("SETTINGS", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "local_chat/discovery",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticastLock" -> {
                    try {
                        if (multicastLock?.isHeld == true) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        val wifi =
                            applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        val lock = wifi.createMulticastLock("local_chat_discovery")
                        lock.setReferenceCounted(false)
                        lock.acquire()
                        multicastLock = lock
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("MULTICAST_LOCK", e.message, null)
                    }
                }
                "releaseMulticastLock" -> {
                    try {
                        multicastLock?.let { l ->
                            if (l.isHeld) l.release()
                        }
                        multicastLock = null
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("MULTICAST_LOCK", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
