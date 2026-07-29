package dev.snehit.vidyut.vidyut_files

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.ConnectivityManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.util.concurrent.Executors
import java.util.UUID

class VidyutFilesPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingResult: MethodChannel.Result? = null
    private val ioExecutor = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(
            binding.binaryMessenger,
            "vidyut/files",
            StandardMethodCodec.INSTANCE,
            binding.binaryMessenger.makeBackgroundTaskQueue()
        )
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        ioExecutor.shutdownNow()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)
    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(this)
        pendingResult?.error(
            "activity-detached",
            "The picker closed before a selection was returned.",
            null
        )
        pendingResult = null
        activityBinding = null
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "chooseDestination" -> Handler(Looper.getMainLooper()).post {
                chooseDestination(result)
            }
            "pickFiles" -> Handler(Looper.getMainLooper()).post {
                pickFiles(result)
            }
            "destinationLabel" -> result.success(destinationLabel())
            "isNetworkMetered" -> {
                val manager =
                    context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                result.success(manager.isActiveNetworkMetered)
            }
            "isDestinationAvailable" -> {
                val tree = preferences().getString(KEY_TREE_URI, null)
                result.success(
                    tree == null ||
                        DocumentFile.fromTreeUri(context, Uri.parse(tree))?.canWrite() == true
                )
            }
            "publish" -> {
                val sourcePath = call.argument<String>("sourcePath")
                val filename = call.argument<String>("filename")
                val mime = call.argument<String>("mime")
                val modified = call.argument<Number>("lastModifiedMs")?.toLong()
                if (sourcePath == null || filename == null || mime == null || modified == null) {
                    result.error("bad-args", "Missing publish arguments.", null)
                    return
                }
                try {
                    result.success(publish(File(sourcePath), filename, mime, modified))
                } catch (error: Exception) {
                    result.error("publish-failed", error.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun chooseDestination(result: MethodChannel.Result) {
        val host = activity
        if (host == null || pendingResult != null) {
            result.error("no-activity", "A visible Vidyut activity is required.", null)
            return
        }
        pendingResult = result
        host.startActivityForResult(
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            ),
            REQUEST_TREE
        )
    }

    private fun pickFiles(result: MethodChannel.Result) {
        val host = activity
        if (host == null || pendingResult != null) {
            result.error("no-activity", "A visible Vidyut activity is required.", null)
            return
        }
        pendingResult = result
        host.startActivityForResult(
            Intent(Intent.ACTION_OPEN_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("*/*")
                .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
            REQUEST_FILES
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_TREE && requestCode != REQUEST_FILES) return false
        val result = pendingResult ?: return true
        pendingResult = null
        if (requestCode == REQUEST_FILES) {
            if (resultCode != Activity.RESULT_OK || data == null) {
                result.success(emptyList<Map<String, String>>())
                return true
            }
            val uris = linkedSetOf<Uri>().apply {
                data.data?.let(::add)
                data.clipData?.let { clipData ->
                    for (index in 0 until clipData.itemCount) add(clipData.getItemAt(index).uri)
                }
            }
            if (uris.size > MAX_PICKED_FILES) {
                result.error(
                    "too-many-files",
                    "Select at most $MAX_PICKED_FILES files at a time.",
                    null
                )
                return true
            }
            ioExecutor.execute {
                try {
                    result.success(uris.map(::copyPickedFile))
                } catch (error: Exception) {
                    result.error("pick-failed", error.message, null)
                }
            }
            return true
        }
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        try {
            context.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
            preferences().edit().putString(KEY_TREE_URI, uri.toString()).apply()
            result.success(destinationLabel())
        } catch (error: Exception) {
            result.error("destination-failed", error.message, null)
        }
        return true
    }

    /**
     * Streams a selected content URI into cache and returns only metadata to Dart.
     *
     * file_selector_android reads the complete URI into a byte array before it
     * returns control to Flutter, which crashes on large files under Android's
     * per-app heap limit. This uses a bounded stream copy instead.
     */
    private fun copyPickedFile(uri: Uri): Map<String, String> {
        val name = selectedFilename(uri)
        val directory = File(context.cacheDir, "vidyut-picker/${UUID.randomUUID()}")
        check(directory.mkdirs()) { "Could not create temporary file storage." }
        val file = File(directory, name)
        context.contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "Could not open selected file." }
            file.outputStream().use { output -> input.copyTo(output) }
        }
        val mime = context.contentResolver.getType(uri)
            ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', ""))
            ?: "application/octet-stream"
        return mapOf("path" to file.path, "filename" to name, "mime" to mime)
    }

    private fun selectedFilename(uri: Uri): String {
        val displayName = context.contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null
        )?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
        }
        return (displayName ?: "vidyut-file-${UUID.randomUUID()}")
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .replace('\u0000', '_')
            .ifBlank { "vidyut-file-${UUID.randomUUID()}" }
    }

    private fun destinationLabel(): String {
        val uri = preferences().getString(KEY_TREE_URI, null) ?: return "Downloads/Vidyut"
        return DocumentFile.fromTreeUri(context, Uri.parse(uri))?.name ?: "Selected folder"
    }

    private fun publish(source: File, filename: String, mime: String, modifiedMs: Long): String {
        require(source.isFile) { "Source file does not exist." }
        val tree = preferences().getString(KEY_TREE_URI, null)
        val destination = if (tree == null) {
            publishToDownloads(source, filename, mime, modifiedMs)
        } else {
            publishToTree(source, Uri.parse(tree), filename, mime)
        }
        // Publishing succeeded. Cleanup is best-effort and must not turn a
        // completed transfer into a reported failure.
        source.delete()
        return destination
    }

    private fun publishToTree(source: File, treeUri: Uri, filename: String, mime: String): String {
        val root = DocumentFile.fromTreeUri(context, treeUri)
            ?: error("Configured destination is no longer available.")
        val unique = uniqueName(filename) { root.findFile(it) != null }
        val target = root.createFile(mime, ".$unique.vidyut-part")
            ?: error("Could not create destination file.")
        try {
            context.contentResolver.openOutputStream(target.uri, "w").use { output ->
                requireNotNull(output) { "Could not open destination." }
                source.inputStream().use { it.copyTo(output) }
            }
            check(target.renameTo(unique)) { "Could not finalize destination file." }
        } catch (error: Exception) {
            target.delete()
            throw error
        }
        return target.uri.toString()
    }

    private fun publishToDownloads(
        source: File,
        filename: String,
        mime: String,
        modifiedMs: Long
    ): String {
        check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            "Public Downloads publishing requires Android 10 or newer."
        }
        val resolver = context.contentResolver
        val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/Vidyut/"
        val unique = uniqueName(filename) { name ->
            resolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND ${MediaStore.MediaColumns.RELATIVE_PATH}=?",
                arrayOf(name, relativePath),
                null
            )?.use { it.moveToFirst() } == true
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, unique)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.DATE_MODIFIED, modifiedMs / 1000)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: error("Could not create Downloads entry.")
        try {
            resolver.openOutputStream(uri, "w").use { output ->
                requireNotNull(output) { "Could not open Downloads entry." }
                source.inputStream().use { it.copyTo(output) }
            }
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null,
                null
            )
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
        return uri.toString()
    }

    private fun uniqueName(filename: String, exists: (String) -> Boolean): String {
        val dot = filename.lastIndexOf('.')
        val stem = if (dot > 0) filename.substring(0, dot) else filename
        val extension = if (dot > 0) filename.substring(dot) else ""
        for (suffix in 0 until 10000) {
            val candidate = if (suffix == 0) filename else "$stem ($suffix)$extension"
            if (!exists(candidate)) return candidate
        }
        error("Could not resolve a collision-free destination.")
    }

    private fun preferences() =
        context.getSharedPreferences("vidyut_files", Context.MODE_PRIVATE)

    companion object {
        private const val REQUEST_TREE = 8401
        private const val REQUEST_FILES = 8402
        private const val MAX_PICKED_FILES = 100
        private const val KEY_TREE_URI = "destination_tree_uri"
    }
}
