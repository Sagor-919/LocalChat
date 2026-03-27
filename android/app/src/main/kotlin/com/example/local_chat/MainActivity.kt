package com.example.local_chat

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlin.io.copyTo

class MainActivity : FlutterActivity() {

    private var multicastLock: WifiManager.MulticastLock? = null

    companion object {
        private val pendingShares = mutableListOf<String>()
        private val pendingLock = Any()
    }

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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "local_chat/share",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "takePendingShares" -> {
                    synchronized(pendingLock) {
                        val out = ArrayList(pendingShares)
                        pendingShares.clear()
                        result.success(out)
                    }
                }
                else -> result.notImplemented()
            }
        }

        ingestShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val added = ingestShareIntent(intent)
        if (added.isNotEmpty()) {
            notifyDartShareUpdated()
        }
    }

    private fun notifyDartShareUpdated() {
        val engine = flutterEngine ?: return
        MethodChannel(engine.dartExecutor.binaryMessenger, "local_chat/share")
            .invokeMethod("shareIntentUpdated", null)
    }

    /** Copies shared content into cache and enqueues absolute paths for Flutter. */
    private fun ingestShareIntent(intent: Intent?): List<String> {
        if (intent == null) return emptyList()
        val action = intent.action ?: return emptyList()
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) {
            return emptyList()
        }

        val uris = mutableListOf<Uri>()
        if (action == Intent.ACTION_SEND) {
            streamSingle(intent)?.let { uris.add(it) }
        } else {
            uris.addAll(streamsMultiple(intent))
        }

        if (uris.isEmpty() && intent.clipData != null) {
            val cd = intent.clipData!!
            for (i in 0 until cd.itemCount) {
                cd.getItemAt(i).uri?.let { uris.add(it) }
            }
        }

        val addedPaths = mutableListOf<String>()
        for (u in uris) {
            val path = copyUriToCache(u) ?: continue
            synchronized(pendingLock) {
                pendingShares.add(path)
            }
            addedPaths.add(path)
        }
        return addedPaths
    }

    @Suppress("DEPRECATION")
    private fun streamSingle(intent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        }
    }

    @Suppress("DEPRECATION")
    private fun streamsMultiple(intent: Intent): List<Uri> {
        return if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                ?: emptyList()
        } else {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
        }
    }

    private fun copyUriToCache(uri: Uri): String? {
        return try {
            val resolver = applicationContext.contentResolver
            val baseName = queryDisplayName(resolver, uri) ?: "shared_${System.currentTimeMillis()}"
            val safeName = baseName.replace(Regex("[^a-zA-Z0-9._-]+"), "_").take(120)
            val dir = File(applicationContext.cacheDir, "share_in").apply { mkdirs() }
            val out = File(dir, "${UUID.randomUUID()}_$safeName")
            resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(out).use { output ->
                    input.copyTo(output)
                }
            } ?: return null
            out.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun queryDisplayName(resolver: ContentResolver, uri: Uri): String? {
        if (uri.scheme == ContentResolver.SCHEME_FILE) {
            return uri.lastPathSegment
        }
        var cursor: Cursor? = null
        try {
            cursor = resolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )
            if (cursor != null && cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) return cursor.getString(idx)
            }
        } catch (_: Exception) {
        } finally {
            cursor?.close()
        }
        return null
    }
}
