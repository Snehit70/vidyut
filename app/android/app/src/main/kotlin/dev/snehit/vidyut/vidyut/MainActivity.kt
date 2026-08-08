package dev.snehit.vidyut.vidyut

import android.content.Context
import android.content.ClipData
import android.net.wifi.WifiManager
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private companion object {
        const val SHARED_STAGE_DIRECTORY = "vidyut_updates/shared"
        const val MAX_SHARED_STAGE_FILES = 8
        const val MAX_SHARED_STAGE_BYTES = 512L * 1024 * 1024
        const val SHARED_STAGE_MAX_AGE_MS = 24L * 60 * 60 * 1000
        const val SHARED_STAGE_GRANT_GRACE_MS = 30L * 60 * 1000
    }

    private var multicastLock: WifiManager.MulticastLock? = null
    private val fileActionExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val grantedStageFiles = ConcurrentHashMap<String, Long>()

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
                handleTransferFileAction(call, result)
            }
    }

    override fun onDestroy() {
        fileActionExecutor.shutdownNow()
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

    private fun handleTransferFileAction(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val path = call.argument<String>("path")
        val uri = call.argument<String>("uri")
        val mime = call.argument<String>("mime") ?: "*/*"
        if (call.method != "open" && call.method != "share") {
            result.notImplemented()
            return
        }
        try {
            fileActionExecutor.execute {
                try {
                    val contentUri = resolveFileUri(path, uri)
                    mainHandler.post {
                        try {
                            when (call.method) {
                                "open" -> launchFileIntent(Intent.ACTION_VIEW, contentUri, mime)
                                "share" -> launchShareIntent(contentUri, mime)
                            }
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("transfer-file-action", error.message, null)
                        }
                    }
                } catch (error: Exception) {
                    mainHandler.post {
                        result.error("transfer-file-action", error.message, null)
                    }
                }
            }
        } catch (error: Exception) {
            result.error("transfer-file-action", error.message, null)
        }
    }

    private fun launchFileIntent(
        action: String,
        contentUri: Uri,
        mime: String,
    ) {
        startActivity(
            Intent(action).apply {
                setDataAndType(contentUri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            },
        )
    }

    private fun launchShareIntent(contentUri: Uri, mime: String) {
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
    }

    private fun resolveFileUri(path: String?, uri: String?): Uri {
        if (uri != null) return Uri.parse(uri)
        require(!path.isNullOrBlank()) { "A file path or document URI is required." }
        val file = File(path)
        return try {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        } catch (_: IllegalArgumentException) {
            pruneSharedStages()
            val safeName = file.name.replace(Regex("[^A-Za-z0-9._-]"), "_")
            val staged = File(
                File(cacheDir, SHARED_STAGE_DIRECTORY),
                "${file.absolutePath.hashCode().toUInt().toString(16)}-$safeName",
            )
            staged.parentFile?.mkdirs()
            try {
                file.copyTo(staged, overwrite = true)
                staged.setLastModified(System.currentTimeMillis())
            } catch (error: Exception) {
                staged.delete()
                throw error
            }
            grantedStageFiles[staged.absolutePath] = System.currentTimeMillis()
            pruneSharedStages(protected = staged)
            FileProvider.getUriForFile(this, "$packageName.fileprovider", staged)
        }
    }

    private fun pruneSharedStages(protected: File? = null) {
        val directory = File(cacheDir, SHARED_STAGE_DIRECTORY)
        val now = System.currentTimeMillis()
        val staleBefore = now - SHARED_STAGE_MAX_AGE_MS
        val grantGraceBefore = now - SHARED_STAGE_GRANT_GRACE_MS

        grantedStageFiles.entries.removeIf { it.value < grantGraceBefore }

        fun isGrantedRecently(file: File): Boolean =
            (grantedStageFiles[file.absolutePath] ?: 0L) >= grantGraceBefore

        val allFiles = directory.listFiles()?.filter { it.isFile } ?: return

        allFiles
            .filter {
                it.lastModified() < staleBefore &&
                    it != protected &&
                    !isGrantedRecently(it)
            }
            .forEach { it.delete() }

        val remaining = allFiles.filter { it.exists() }.sortedBy { it.lastModified() }
        var count = remaining.size
        var totalBytes = remaining.sumOf { it.length() }
        for (file in remaining) {
            if (count <= MAX_SHARED_STAGE_FILES &&
                totalBytes <= MAX_SHARED_STAGE_BYTES) {
                break
            }
            if (file == protected || isGrantedRecently(file)) continue
            val size = file.length()
            if (file.delete()) {
                count--
                totalBytes -= size
                grantedStageFiles.remove(file.absolutePath)
            }
        }
    }
}
