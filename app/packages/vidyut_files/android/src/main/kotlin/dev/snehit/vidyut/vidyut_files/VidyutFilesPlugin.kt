package dev.snehit.vidyut.vidyut_files

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.ConnectivityManager
import android.os.CancellationSignal
import android.os.Build
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.system.Os
import android.system.OsConstants
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
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.util.concurrent.atomic.AtomicBoolean
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
    private val engineAttached = AtomicBoolean(false)
    private val stageCancellations = java.util.concurrent.ConcurrentHashMap<String, AtomicBoolean>()
    private val hashCancellations = java.util.concurrent.ConcurrentHashMap<String, AtomicBoolean>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        engineAttached.set(true)
        context = binding.applicationContext
        channel = MethodChannel(
            binding.binaryMessenger,
            "vidyut/files",
            StandardMethodCodec.INSTANCE,
            binding.binaryMessenger.makeBackgroundTaskQueue()
        )
        channel.setMethodCallHandler(this)
        cleanupPartialStages()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        engineAttached.set(false)
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
            "probeSource" -> {
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                if (uri == null) {
                    result.error("bad-args", "Missing source URI.", null)
                    return
                }
                ioExecutor.execute {
                    try {
                        if (engineAttached.get()) result.success(probeSource(uri))
                    } catch (error: Exception) {
                        if (engineAttached.get()) {
                            result.error("source-unavailable", error.message, null)
                        }
                    }
                }
            }
            "hashSource" -> {
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                val operationId = call.argument<String>("operationId") ?: UUID.randomUUID().toString()
                if (uri == null) {
                    result.error("bad-args", "Missing source URI.", null)
                    return
                }
                val cancelled = AtomicBoolean(false)
                hashCancellations[operationId] = cancelled
                ioExecutor.execute {
                    try {
                        if (engineAttached.get()) result.success(hashSource(uri.toString(), cancelled))
                    } catch (error: Exception) {
                        if (engineAttached.get()) {
                            result.error("source-unavailable", error.message, null)
                        }
                    } finally {
                        hashCancellations.remove(operationId, cancelled)
                    }
                }
            }
            "stageSource" -> {
                val uri = call.argument<String>("uri")
                val operationId = call.argument<String>("operationId") ?: UUID.randomUUID().toString()
                val maximumBytes = call.argument<Number>("maximumBytes")?.toLong()
                    ?: DEFAULT_MAX_STAGE_BYTES
                if (uri == null || maximumBytes < 0) {
                    result.error("bad-args", "Invalid stage arguments.", null)
                    return
                }
                val cancelled = AtomicBoolean(false)
                stageCancellations[operationId] = cancelled
                ioExecutor.execute {
                    try {
                        if (engineAttached.get()) result.success(stageSource(Uri.parse(uri), maximumBytes, cancelled))
                    } catch (error: Exception) {
                        if (engineAttached.get()) {
                            result.error("source-stage-failed", error.message, null)
                        }
                    } finally {
                        stageCancellations.remove(operationId, cancelled)
                    }
                }
            }
            "cancelStage" -> {
                val operationId = call.argument<String>("operationId")
                if (operationId == null) result.error("bad-args", "Missing operation ID.", null)
                else {
                    stageCancellations[operationId]?.set(true)
                    result.success(null)
                }
            }
            "cancelHash" -> {
                val operationId = call.argument<String>("operationId")
                if (operationId == null) result.error("bad-args", "Missing operation ID.", null)
                else {
                    hashCancellations[operationId]?.set(true)
                    result.success(null)
                }
            }
            "readSourceAt" -> {
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                val offset = call.argument<Number>("offset")?.toLong()
                val length = call.argument<Number>("length")?.toInt()
                if (uri == null || offset == null || length == null ||
                    offset < 0 || length < 0 || length > MAX_READ_BYTES) {
                    result.error("bad-args", "Invalid source read arguments.", null)
                    return
                }
                ioExecutor.execute {
                    try {
                        if (engineAttached.get()) result.success(readSourceAt(uri.toString(), offset, length))
                    } catch (error: Exception) {
                        if (engineAttached.get()) {
                            result.error("source-unavailable", error.message, null)
                        }
                    }
                }
            }
            "releaseSource" -> {
                val reference = call.argument<String>("uri")
                if (reference?.startsWith(STAGE_PREFIX) == true) {
                    ioExecutor.execute {
                        try {
                            deleteStage(reference)
                        } finally {
                            if (engineAttached.get()) result.success(null)
                        }
                    }
                } else {
                    if (reference?.startsWith("content://") == true) {
                        val key = grantKey(reference)
                        val count = preferences().getInt(key, 0)
                        if (count <= 1) {
                            preferences().edit().remove(key).apply()
                            try {
                                context.contentResolver.releasePersistableUriPermission(
                                    Uri.parse(reference),
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                                )
                            } catch (_: SecurityException) {
                                // The provider may already have revoked it.
                            }
                        } else {
                            preferences().edit().putInt(key, count - 1).apply()
                        }
                    }
                    result.success(null)
                }
            }
            "retainSource" -> {
                val reference = call.argument<String>("uri")
                if (reference?.startsWith("content://") == true) {
                    val key = grantKey(reference)
                    val count = preferences().getInt(key, 0)
                    preferences().edit().putInt(key, count + 1).apply()
                }
                result.success(null)
            }
            "discardSource" -> {
                val reference = call.argument<String>("reference")
                if (reference?.startsWith(STAGE_PREFIX) == true) {
                    ioExecutor.execute {
                        try {
                            deleteStage(reference)
                        } catch (_: Exception) {
                            // Discarding an absent stage is a no-op.
                        } finally {
                            if (engineAttached.get()) result.success(null)
                        }
                    }
                } else {
                    result.success(null)
                }
            }
            "publish" -> {
                val sourcePath = call.argument<String>("sourcePath")
                val filename = call.argument<String>("filename")
                val mime = call.argument<String>("mime")
                val modified = call.argument<Number>("lastModifiedMs")?.toLong()
                if (sourcePath == null || filename == null || mime == null) {
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
                .addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                ),
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
                val files = uris.map { uri -> describePickedFile(uri, data.flags) }
                if (engineAttached.get()) result.success(files)
            }
            return true
        }
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        try {
            val takeFlags = VidyutFileGrantFlags.destinationFlags(data.flags)
            check(takeFlags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0) {
                "Picker did not return a writable persistable grant."
            }
            context.contentResolver.takePersistableUriPermission(uri, takeFlags)
            preferences().edit().putString(KEY_TREE_URI, uri.toString()).apply()
            result.success(destinationLabel())
        } catch (error: Exception) {
            result.error("destination-failed", error.message, null)
        }
        return true
    }

    private fun describePickedFile(uri: Uri, returnedFlags: Int): Map<String, Any?> {
        val name = selectedFilename(uri)
        var persisted = false
        var grantError: String? = null
        val takeFlags = VidyutFileGrantFlags.sourceFlags(returnedFlags)
        if (takeFlags != 0) {
            try {
                context.contentResolver.takePersistableUriPermission(uri, takeFlags)
                persisted = true
                val key = grantKey(uri.toString())
                val count = preferences().getInt(key, 0)
                preferences().edit().putInt(key, count + 1).apply()
            } catch (error: Exception) {
                grantError = error.javaClass.simpleName
            }
        } else {
            grantError = "missing-read-grant"
        }
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', ""))
            ?: "application/octet-stream"
        return buildMap {
            put("uri", uri.toString())
            put("filename", name)
            put("mime", mime)
            put("persisted", persisted)
            if (grantError != null) put("grantError", grantError)
        }
    }

    private fun cleanupPartialStages() {
        File(context.filesDir, "vidyut-stages").listFiles()?.forEach { file ->
            if (file.name.endsWith(".partial")) file.delete()
        }
    }

    private fun openSource(uri: Uri, signal: CancellationSignal? = null): ParcelFileDescriptor {
        return context.contentResolver.openFileDescriptor(uri, "r", signal)
            ?: error("Provider returned no readable descriptor.")
    }

    private fun probeSource(uri: Uri): Map<String, Any> {
        if (uri.toString().startsWith(STAGE_PREFIX)) {
            val size = stageSize(uri.toString())
            return mapOf("seekable" to true, "size" to size, "sizeKnown" to true)
        }
        val descriptor = openSource(uri)
        descriptor.use { pfd ->
            val size = pfd.statSize
            val fd = pfd.fileDescriptor
            return try {
                val current = Os.lseek(fd, 0, OsConstants.SEEK_CUR)
                Os.lseek(fd, 0, OsConstants.SEEK_SET)
                if (size > 0) {
                    val one = ByteArray(1)
                    check(Os.read(fd, one, 0, 1) == 1) { "Provider read probe failed." }
                }
                Os.lseek(fd, current, OsConstants.SEEK_SET)
                buildMap {
                    put("seekable", true)
                    put("size", size.coerceAtLeast(0))
                    put("sizeKnown", size >= 0)
                    val metadata = sourceMetadata(uri)
                    metadata.first?.let { put("filename", it) }
                    metadata.second?.let { put("mime", it) }
                }
            } catch (_: Exception) {
                buildMap {
                    put("seekable", false)
                    put("size", size.coerceAtLeast(0))
                    put("sizeKnown", size >= 0)
                    val metadata = sourceMetadata(uri)
                    metadata.first?.let { put("filename", it) }
                    metadata.second?.let { put("mime", it) }
                }
            }
        }
    }

    private fun hashSource(reference: String, cancelled: AtomicBoolean): String {
        if (reference.startsWith(STAGE_PREFIX)) return hashStage(reference, cancelled)
        val uri = Uri.parse(reference)
        val digest = MessageDigest.getInstance("SHA-256")
        val descriptor = openSource(uri)
        ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
            val buffer = ByteArray(BUFFER_BYTES)
            while (true) {
                check(!cancelled.get()) { "Source hashing cancelled." }
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun readSourceAt(reference: String, offset: Long, length: Int): ByteArray {
        if (length == 0) return ByteArray(0)
        if (reference.startsWith(STAGE_PREFIX)) {
            return readStageAt(reference, offset, length)
        }
        val uri = Uri.parse(reference)
        val descriptor = openSource(uri)
        descriptor.use { pfd ->
            Os.lseek(pfd.fileDescriptor, offset, OsConstants.SEEK_SET)
            val bytes = ByteArray(length)
            var total = 0
            while (total < length) {
                val count = Os.read(pfd.fileDescriptor, bytes, total, length - total)
                if (count <= 0) break
                total += count
            }
            return if (total == bytes.size) bytes else bytes.copyOf(total)
        }
    }

    private fun stageSource(uri: Uri, maximumBytes: Long, cancelled: AtomicBoolean): Map<String, Any?> {
        val directory = File(context.filesDir, "vidyut-stages")
        check(directory.mkdirs() || directory.isDirectory) { "Could not create stage storage." }
        val id = UUID.randomUUID().toString()
        val partial = File(directory, "$id.partial")
        val published = File(directory, id)
        val indexPartial = File(directory, "$id.index.partial")
        val index = File(directory, "$id.index")
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        var fileOffset = 0L
        val indexEntries = mutableListOf<StageIndexEntry>()
        try {
            val descriptor = openSource(uri)
            ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
                DataOutputStream(BufferedOutputStream(partial.outputStream())).use { output ->
                    val buffer = ByteArray(STAGE_BLOCK_BYTES)
                    while (true) {
                        check(!cancelled.get()) { "Source staging cancelled." }
                        val count = input.read(buffer)
                        if (count < 0) break
                        indexEntries += StageIndexEntry(total, fileOffset)
                        total += count
                        check(total <= maximumBytes) { "Selected source exceeds the configured maximum." }
                        digest.update(buffer, 0, count)
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                        cipher.init(Cipher.ENCRYPT_MODE, stageKey())
                        val nonce = cipher.iv
                        check(nonce.size == GCM_NONCE_BYTES) { "Unexpected GCM nonce length." }
                        val encrypted = cipher.doFinal(buffer, 0, count)
                        output.writeInt(count)
                        output.write(nonce)
                        output.writeInt(encrypted.size)
                        output.write(encrypted)
                        fileOffset += 4L + GCM_NONCE_BYTES + 4L + encrypted.size
                    }
                }
            }
            check(!cancelled.get()) { "Source staging cancelled." }
            DataOutputStream(indexPartial.outputStream()).use { output ->
                indexEntries.forEach { entry ->
                    output.writeLong(entry.logicalOffset)
                    output.writeLong(entry.fileOffset)
                }
            }
            check(partial.renameTo(published)) { "Could not publish staged source." }
            check(indexPartial.renameTo(index)) { "Could not publish staged source index." }
            return mapOf(
                "reference" to "$STAGE_PREFIX$id",
                "size" to total,
                "sha256" to digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) },
            )
        } catch (error: Exception) {
            partial.delete()
            published.delete()
            indexPartial.delete()
            index.delete()
            throw error
        }
    }

    private fun stageId(reference: String): String {
        val id = reference.removePrefix(STAGE_PREFIX)
        require(id.matches(Regex("[0-9a-fA-F-]{36}"))) { "Invalid managed stage reference." }
        return id
    }

    private fun stageFile(reference: String): File {
        val id = stageId(reference)
        return File(File(context.filesDir, "vidyut-stages"), id).also {
            check(it.isFile) { "Managed staged source is unavailable." }
        }
    }

    private fun stageIndexFile(reference: String): File {
        return File(File(context.filesDir, "vidyut-stages"), "${stageId(reference)}.index")
    }

    private fun deleteStage(reference: String) {
        stageFile(reference).delete()
        stageIndexFile(reference).delete()
    }

    private fun stageSize(reference: String): Long {
        var total = 0L
        DataInputStream(BufferedInputStream(stageFile(reference).inputStream())).use { input ->
            while (true) {
                val count = try { input.readInt() } catch (_: java.io.EOFException) { break }
                input.skipBytes(GCM_NONCE_BYTES)
                val encryptedSize = input.readInt()
                input.skipNBytes(encryptedSize.toLong())
                total += count
            }
        }
        return total
    }

    private fun hashStage(reference: String, cancelled: AtomicBoolean): String {
        val digest = MessageDigest.getInstance("SHA-256")
        readStageBlocks(reference, cancelled) { bytes, count ->
            digest.update(bytes, 0, count)
            true
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun readStageAt(reference: String, offset: Long, length: Int): ByteArray {
        require(offset >= 0) { "Offset must be non-negative." }
        require(offset <= Long.MAX_VALUE - length) { "Source read exceeds the addressable range." }
        val output = ByteArray(length)
        if (length == 0) return output
        val index = readStageIndex(reference)
        if (index.isNotEmpty()) {
            return readIndexedStageAt(reference, offset, length, index)
        }
        var outputOffset = 0
        var logicalOffset = 0L
        readStageBlocks(reference, block = { bytes, count ->
            val blockStart = logicalOffset
            val blockEnd = logicalOffset + count
            val requestedStart = maxOf(offset, blockStart)
            val requestedEnd = minOf(offset + length, blockEnd)
            if (requestedStart < requestedEnd) {
                val copy = (requestedEnd - requestedStart).toInt()
                bytes.copyInto(output, outputOffset, (requestedStart - blockStart).toInt(), (requestedStart - blockStart).toInt() + copy)
                outputOffset += copy
            }
            logicalOffset = blockEnd
            outputOffset < output.size
        })
        return if (outputOffset == output.size) output else output.copyOf(outputOffset)
    }

    private fun readIndexedStageAt(
        reference: String,
        offset: Long,
        length: Int,
        index: List<StageIndexEntry>,
    ): ByteArray {
        val targetEnd = offset + length
        var low = 0
        var high = index.size - 1
        var selected = 0
        while (low <= high) {
            val middle = (low + high) ushr 1
            if (index[middle].logicalOffset <= offset) {
                selected = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        val output = ByteArray(length)
        var outputOffset = 0
        RandomAccessFile(stageFile(reference), "r").use { input ->
            input.seek(index[selected].fileOffset)
            var logicalOffset = index[selected].logicalOffset
            while (logicalOffset < targetEnd) {
                val count = input.readInt()
                val nonce = ByteArray(GCM_NONCE_BYTES)
                input.readFully(nonce)
                val encryptedSize = input.readInt()
                val encrypted = ByteArray(encryptedSize)
                input.readFully(encrypted)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, stageKey(), GCMParameterSpec(128, nonce))
                val bytes = cipher.doFinal(encrypted)
                check(bytes.size == count) { "Managed stage is corrupt." }
                val blockStart = logicalOffset
                val blockEnd = logicalOffset + count
                val requestedStart = maxOf(offset, blockStart)
                val requestedEnd = minOf(targetEnd, blockEnd)
                if (requestedStart < requestedEnd) {
                    val copy = (requestedEnd - requestedStart).toInt()
                    bytes.copyInto(
                        output,
                        outputOffset,
                        (requestedStart - blockStart).toInt(),
                        (requestedStart - blockStart).toInt() + copy,
                    )
                    outputOffset += copy
                }
                logicalOffset = blockEnd
            }
        }
        return if (outputOffset == output.size) output else output.copyOf(outputOffset)
    }

    private fun readStageBlocks(
        reference: String,
        cancelled: AtomicBoolean? = null,
        block: (ByteArray, Int) -> Boolean,
    ) {
        DataInputStream(BufferedInputStream(stageFile(reference).inputStream())).use { input ->
            while (true) {
                check(cancelled?.get() != true) { "Source hashing cancelled." }
                val count = try { input.readInt() } catch (_: java.io.EOFException) { break }
                val nonce = ByteArray(GCM_NONCE_BYTES)
                input.readFully(nonce)
                val encryptedSize = input.readInt()
                val encrypted = ByteArray(encryptedSize)
                input.readFully(encrypted)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, stageKey(), GCMParameterSpec(128, nonce))
                val bytes = cipher.doFinal(encrypted)
                check(bytes.size == count) { "Managed stage is corrupt." }
                if (!block(bytes, count)) break
            }
        }
    }

    private fun readStageIndex(reference: String): List<StageIndexEntry> {
        val file = stageIndexFile(reference)
        if (!file.isFile) return emptyList()
        val entries = mutableListOf<StageIndexEntry>()
        DataInputStream(BufferedInputStream(file.inputStream())).use { input ->
            while (true) {
                try {
                    entries += StageIndexEntry(input.readLong(), input.readLong())
                } catch (_: java.io.EOFException) {
                    break
                }
            }
        }
        return entries
    }

    private data class StageIndexEntry(
        val logicalOffset: Long,
        val fileOffset: Long,
    )

    private fun stageKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!store.containsAlias(STAGE_KEY_ALIAS)) {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(
                    KeyGenParameterSpec.Builder(
                        STAGE_KEY_ALIAS,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                    ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .build(),
                )
                generateKey()
            }
        }
        return (store.getKey(STAGE_KEY_ALIAS, null) as SecretKey)
    }

    private fun selectedFilename(uri: Uri): String {
        // Do not query provider metadata on the picker callback path. A slow
        // cloud provider must not delay creation of the durable transfer row.
        val displayName = uri.lastPathSegment?.let(Uri::decode)
        val name = (displayName ?: "vidyut-file-${UUID.randomUUID()}")
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .replace('\u0000', '_')
        return if (name.isBlank() || name == "." || name == "..") {
            "vidyut-file-${UUID.randomUUID()}"
        } else {
            name
        }
    }

    private fun sourceMetadata(uri: Uri): Pair<String?, String?> {
        val displayName = try {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    cursor.getString(cursor.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME))
                } else {
                    null
                }
            }
        } catch (_: Exception) {
            null
        }
        val mime = try {
            context.contentResolver.getType(uri)
        } catch (_: Exception) {
            null
        }
        return displayName to mime
    }

    private fun destinationLabel(): String {
        val uri = preferences().getString(KEY_TREE_URI, null) ?: return "Downloads/Vidyut"
        return DocumentFile.fromTreeUri(context, Uri.parse(uri))?.name ?: "Selected folder"
    }

    private fun publish(source: File, filename: String, mime: String, modifiedMs: Long?): String {
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
        modifiedMs: Long?,
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
            modifiedMs?.let { put(MediaStore.MediaColumns.DATE_MODIFIED, it / 1000) }
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

    private fun grantKey(uri: String) =
        "grant_count_${uri.hashCode().toUInt().toString(16)}"

    companion object {
        private const val REQUEST_TREE = 8401
        private const val REQUEST_FILES = 8402
        private const val MAX_PICKED_FILES = 100
        private const val MAX_READ_BYTES = 1024 * 1024
        private const val BUFFER_BYTES = 256 * 1024
        private const val STAGE_BLOCK_BYTES = 256 * 1024
        private const val GCM_NONCE_BYTES = 12
        private const val DEFAULT_MAX_STAGE_BYTES = 1024L * 1024L * 1024L
        private const val STAGE_PREFIX = "stage:"
        private const val STAGE_KEY_ALIAS = "vidyut-transfer-stage-v1"
        private const val KEY_TREE_URI = "destination_tree_uri"
    }
}

internal object VidyutFileGrantFlags {
    fun sourceFlags(returnedFlags: Int): Int =
        returnedFlags and Intent.FLAG_GRANT_READ_URI_PERMISSION

    fun destinationFlags(returnedFlags: Int): Int =
        returnedFlags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
}
