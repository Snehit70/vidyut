package dev.snehit.vidyut.vidyut

import android.content.Context
import android.content.ClipData
import android.net.wifi.WifiManager
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vidyut/multicast")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        try {
                            acquireMulticastLock()
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("multicast-lock", error.message, null)
                        }
                    }
                    "release" -> {
                        try {
                            releaseMulticastLock()
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("multicast-lock", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vidyut/updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstall" -> result.success(packageManager.canRequestPackageInstalls())
                    "openInstallSettings" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                        result.success(null)
                    }
                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("missing-path", "APK path is required.", null)
                        } else {
                            try {
                                val uri = FileProvider.getUriForFile(
                                    this,
                                    "$packageName.fileprovider",
                                    File(path),
                                )
                                startActivity(
                                    Intent(Intent.ACTION_VIEW).apply {
                                        setDataAndType(uri, "application/vnd.android.package-archive")
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    },
                                )
                                result.success(null)
                            } catch (error: Exception) {
                                result.error("install-failed", error.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vidyut/transfer_files")
            .setMethodCallHandler { call, result ->
                try {
                    val path = call.argument<String>("path")
                    val uri = call.argument<String>("uri")
                    val mime = call.argument<String>("mime") ?: "*/*"
                    when (call.method) {
                        "open" -> {
                            launchFileIntent(Intent.ACTION_VIEW, path, uri, mime)
                            result.success(null)
                        }
                        "showFolder" -> {
                            val folder = path?.let { File(it).parentFile?.path }
                            launchFileIntent(
                                Intent.ACTION_VIEW,
                                folder,
                                null,
                                "resource/folder",
                            )
                            result.success(null)
                        }
                        "share" -> {
                            val contentUri = resolveFileUri(path, uri)
                            startActivity(
                                Intent.createChooser(
                                    Intent(Intent.ACTION_SEND).apply {
                                        type = mime
                                        putExtra(Intent.EXTRA_STREAM, contentUri)
                                        clipData = ClipData.newRawUri("Vidyut file", contentUri)
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    },
                                    "Share file",
                                ),
                            )
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("transfer-file-action", error.message, null)
                }
            }
    }

    override fun onDestroy() {
        releaseMulticastLock()
        multicastLock = null
        super.onDestroy()
    }

    private fun acquireMulticastLock() {
        val lock = multicastLock
            ?: (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                .createMulticastLock("vidyut-mdns")
                .also {
                    it.setReferenceCounted(false)
                    multicastLock = it
                }
        if (!lock.isHeld) lock.acquire()
    }

    private fun releaseMulticastLock() {
        multicastLock?.takeIf { it.isHeld }?.release()
    }

    private fun launchFileIntent(
        action: String,
        path: String?,
        uri: String?,
        mime: String,
    ) {
        val contentUri = resolveFileUri(path, uri)
        startActivity(
            Intent(action).apply {
                setDataAndType(contentUri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            },
        )
    }

    private fun resolveFileUri(path: String?, uri: String?): Uri {
        if (uri != null) return Uri.parse(uri)
        require(!path.isNullOrBlank()) { "A file path or document URI is required." }
        return FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            File(path),
        )
    }
}
