package com.example.local_chat

import android.content.Context
import android.net.wifi.WifiManager
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
