package com.example.local_chat

import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.Collections
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val pendingShareUris = Collections.synchronizedList(ArrayList<String>())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) {
            return
        }
        when (action) {
            Intent.ACTION_SEND -> {
                val uri = getSendUriCompat(intent)
                if (uri != null) {
                    pendingShareUris.add(uri.toString())
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val list = getSendUrisCompat(intent)
                if (list != null) {
                    for (u in list) {
                        pendingShareUris.add(u.toString())
                    }
                }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun getSendUriCompat(intent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
    }

    @Suppress("DEPRECATION")
    private fun getSendUrisCompat(intent: Intent): ArrayList<Uri>? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        if (uri.scheme == "file") {
            return uri.lastPathSegment?.let { java.net.URLDecoder.decode(it, Charsets.UTF_8.name()) }
        }
        var cursor: Cursor? = null
        try {
            cursor = contentResolver.query(uri, null, null, null, null)
            if (cursor != null && cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) {
                    val n = cursor.getString(idx)
                    if (!n.isNullOrBlank()) return n
                }
            }
        } catch (_: Exception) {
        } finally {
            cursor?.close()
        }
        return null
    }

    /// Share rows for Flutter: `file` → path on disk; `content` → URI only (copy at send time).
    private fun describeShareForDart(uri: Uri): Map<String, String>? {
        try {
            if (uri.scheme == "file") {
                val rawPath = uri.path ?: return null
                val path = java.net.URLDecoder.decode(rawPath, Charsets.UTF_8.name())
                val f = File(path)
                if (!f.exists() || !f.isFile) return null
                return mapOf("path" to f.absolutePath, "name" to f.name)
            }
            if (uri.scheme == "content") {
                val displayName =
                    queryDisplayName(uri) ?: "shared_${System.currentTimeMillis()}"
                return mapOf("contentUri" to uri.toString(), "name" to displayName)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return null
    }

    private fun materializeContentUriToFile(uri: Uri, destFile: File): Boolean {
        try {
            if (uri.scheme != "content") return false
            val input = contentResolver.openInputStream(uri) ?: return false
            destFile.parentFile?.mkdirs()
            FileOutputStream(destFile).use { out ->
                input.use { inp -> inp.copyTo(out) }
            }
            return destFile.exists()
        } catch (e: Exception) {
            e.printStackTrace()
            try {
                if (destFile.exists()) destFile.delete()
            } catch (_: Exception) {
            }
        }
        return false
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
                "drainPendingShares" -> {
                    ioExecutor.execute {
                        try {
                            val out = ArrayList<Map<String, String>>()
                            val copy = synchronized(pendingShareUris) {
                                val c = ArrayList(pendingShareUris)
                                pendingShareUris.clear()
                                c
                            }
                            for (uriStr in copy) {
                                val uri = Uri.parse(uriStr)
                                val m = describeShareForDart(uri)
                                if (m != null) {
                                    out.add(m)
                                }
                            }
                            mainHandler.post {
                                result.success(out)
                            }
                        } catch (e: Exception) {
                            mainHandler.post {
                                result.error("SHARE", e.message, null)
                            }
                        }
                    }
                }
                "materializeContentUri" -> {
                    val uriStr = call.argument<String>("uri")
                    val destPath = call.argument<String>("destPath")
                    if (uriStr.isNullOrEmpty() || destPath.isNullOrEmpty()) {
                        result.error("ARG", "uri and destPath required", null)
                        return@setMethodCallHandler
                    }
                    ioExecutor.execute {
                        try {
                            val ok =
                                materializeContentUriToFile(Uri.parse(uriStr), File(destPath))
                            mainHandler.post {
                                if (ok) {
                                    result.success(null)
                                } else {
                                    result.error("SHARE", "materialize failed", null)
                                }
                            }
                        } catch (e: Exception) {
                            mainHandler.post {
                                result.error("SHARE", e.message, null)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
