package dev.snehit.vidyut.clipboard_autosend

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Hosts the clipboard auto-send channels from application context.
 *
 * As a plugin in GeneratedPluginRegistrant it attaches to every FlutterEngine —
 * the activity engine and the headless foreground-service engine alike — so the
 * service isolate drives a single [ClipboardAutoSendWatcher]. The watcher state
 * (logcat process, reader thread, registered clip-change listener) lives in the
 * process-wide singleton, not this instance, so a service restart never leaks a
 * second logcat process (read-logs-auto-text D2).
 */
class ClipboardAutoSendPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel =
            MethodChannel(binding.binaryMessenger, "vidyut/clipboard_autosend")
        methodChannel.setMethodCallHandler(this)
        eventChannel =
            EventChannel(binding.binaryMessenger, "vidyut/clipboard_autosend_events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        when (call.method) {
            "hasReadLogsPermission" ->
                result.success(ClipboardAutoSendWatcher.hasReadLogsPermission(context))
            "readText" ->
                ClipboardAutoSendWatcher.requestManualRead(context, result)
            "start" -> {
                ClipboardAutoSendWatcher.start(context)
                result.success(null)
            }
            "stop" -> {
                ClipboardAutoSendWatcher.stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // Only the service isolate listens (D2); the singleton fans events out to
    // whichever engine sinks are active.
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        ClipboardAutoSendWatcher.addSink(events)
    }

    override fun onCancel(arguments: Any?) {
        // The framework hands no sink to onCancel; the singleton drops sinks whose
        // engine detached the next time it fans out. Nothing to do here.
    }
}

/**
 * Process-wide clipboard-change watcher (read-logs-auto-text §"The mechanism").
 *
 * Q+ path: an [ClipboardManager.OnPrimaryClipChangedListener] is registered only
 * to provoke the platform's background-read denial, which is logged by
 * ClipboardService. A long-lived `logcat` subprocess filtered to that tag scans
 * for a denial naming our package; each match launches the invisible
 * [ClipboardReadActivity], which reads the clip while focused and forwards it
 * back through [onClipboardRead]. Without READ_LOGS the subprocess never sees the
 * system tag, so the watcher is inert (the degradation gate).
 *
 * Legacy path (API < 29): background clipboard reads are permitted, so the
 * listener reads directly with no logcat/activity hack.
 *
 * [start] is idempotent; [stop] destroys the subprocess, joins the reader
 * thread, and unregisters the listener.
 */
object ClipboardAutoSendWatcher {
    // Collapse denial bursts (a single copy can log several denials, and the
    // read activity is singleInstance anyway).
    private const val LAUNCH_THROTTLE_MS = 400L
    private const val MANUAL_READ_TIMEOUT_MS = 5_000L

    private val mainHandler = Handler(Looper.getMainLooper())
    private val sinks = CopyOnWriteArraySet<EventChannel.EventSink>()

    private var appContext: Context? = null
    private var logcatProcess: Process? = null
    private var readerThread: Thread? = null
    private var clipListener: ClipboardManager.OnPrimaryClipChangedListener? = null
    private var lastLaunchAtMs = 0L
    private var pendingManualRead: MethodChannel.Result? = null

    fun addSink(sink: EventChannel.EventSink) {
        sinks.add(sink)
    }

    fun hasReadLogsPermission(context: Context): Boolean {
        return context.applicationContext.checkSelfPermission(
            android.Manifest.permission.READ_LOGS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    @Synchronized
    fun requestManualRead(context: Context, result: MethodChannel.Result) {
        if (pendingManualRead != null) {
            result.error(
                "read-in-progress",
                "A clipboard read is already in progress.",
                null,
            )
            return
        }
        pendingManualRead = result
        mainHandler.postDelayed({
            val timedOut = synchronized(this) {
                if (pendingManualRead !== result) {
                    false
                } else {
                    pendingManualRead = null
                    true
                }
            }
            if (timedOut) {
                result.error(
                    "read-timeout",
                    "The clipboard reader did not gain focus.",
                    null,
                )
            }
        }, MANUAL_READ_TIMEOUT_MS)
        val intent = Intent(context, ClipboardReadActivity::class.java).apply {
            putExtra(ClipboardReadActivity.EXTRA_MANUAL_READ, true)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
        }
        try {
            context.startActivity(intent)
        } catch (error: Exception) {
            pendingManualRead = null
            result.error(
                "activity-launch-failed",
                "Could not open the clipboard reader: ${error.message}",
                null,
            )
        }
    }

    @Synchronized
    fun start(context: Context) {
        if (clipListener != null || logcatProcess != null) return // idempotent
        val app = context.applicationContext
        appContext = app

        val manager = app.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val direct = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q
        val listener = ClipboardManager.OnPrimaryClipChangedListener {
            // Q+: the callback is suppressed in the background; registering it
            // only provokes the denial the logcat watcher keys on. Pre-Q the
            // callback fires and can read directly.
            if (direct) readPrimaryClip(manager)
        }
        clipListener = listener
        // Register on the main looper so callbacks (legacy path) are delivered
        // on a thread with a Looper.
        mainHandler.post { manager.addPrimaryClipChangedListener(listener) }

        if (direct) {
            emitLog(
                "Clipboard auto-send watcher started: legacy direct-read path " +
                    "(API ${Build.VERSION.SDK_INT}, no logcat).",
            )
            return
        }

        val filter = priorityFilter()
        emitLog(
            "Clipboard auto-send watcher started: logcat filter='$filter' " +
                "(API ${Build.VERSION.SDK_INT}).",
        )
        startLogcat(app, filter)
    }

    @Synchronized
    fun stop() {
        val app = appContext
        val manager =
            app?.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        clipListener?.let { l ->
            mainHandler.post { manager?.removePrimaryClipChangedListener(l) }
        }
        clipListener = null

        logcatProcess?.destroy()
        logcatProcess = null
        readerThread?.let { thread ->
            thread.interrupt()
            try {
                thread.join(1000)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        readerThread = null
        emitLog("Clipboard auto-send watcher stopped.")
    }

    // Android 15 switched the logcat filterspec syntax (KDE ClipboardListener.kt).
    private fun priorityFilter(): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            "E ClipboardService"
        } else {
            "ClipboardService:E"
        }
    }

    private fun startLogcat(context: Context, filter: String) {
        val packageName = context.packageName
        // -T <start> tails from now so stale denials never replay; *:S silences
        // every other tag. Split the version-branched filter into its tokens.
        val startTimestamp =
            SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US).format(Date())
        val command = ArrayList<String>().apply {
            add("logcat")
            add("-T")
            add(startTimestamp)
            addAll(filter.split(" "))
            add("*:S")
        }
        val thread = Thread({
            try {
                val process = ProcessBuilder(command)
                    .redirectErrorStream(true)
                    .start()
                synchronized(this) { logcatProcess = process }
                BufferedReader(InputStreamReader(process.inputStream)).use { reader ->
                    while (!Thread.currentThread().isInterrupted) {
                        val line = reader.readLine() ?: break
                        // Our own package id in a ClipboardService denial line is
                        // the "clipboard just changed" signal (D2). Never log the
                        // line — it may name apps; only that a denial matched.
                        if (line.contains(packageName)) onDenial(context)
                    }
                }
            } catch (_: InterruptedException) {
                // stop() asked us to exit.
            } catch (e: Exception) {
                emitLog("Clipboard auto-send logcat reader ended: ${e.message}")
            }
        }, "vidyut-clipboard-autosend-logcat")
        thread.isDaemon = true
        readerThread = thread
        thread.start()
    }

    private fun onDenial(context: Context) {
        val now = System.currentTimeMillis()
        synchronized(this) {
            if (now - lastLaunchAtMs < LAUNCH_THROTTLE_MS) return
            lastLaunchAtMs = now
        }
        emitLog("Clipboard denial matched; launching invisible read activity.")
        val intent = Intent(context, ClipboardReadActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
        }
        try {
            context.startActivity(intent)
        } catch (e: Exception) {
            emitLog("Invisible read activity launch failed: ${e.message}")
        }
    }

    private fun readPrimaryClip(manager: ClipboardManager) {
        val app = appContext ?: return
        val text = manager.primaryClip
            ?.takeIf { it.itemCount > 0 }
            ?.getItemAt(0)
            ?.coerceToText(app)
            ?.toString()
        if (!text.isNullOrEmpty()) onClipboardRead(text)
    }

    /**
     * Called by [ClipboardReadActivity] (Q+) or the direct listener (legacy)
     * with freshly read clipboard text. Forwarded to the service isolate, which
     * owns the echo guard and the publish path (D3/D4).
     */
    fun onClipboardRead(text: String?, manual: Boolean = false) {
        if (manual) {
            val result = synchronized(this) {
                pendingManualRead.also { pendingManualRead = null }
            }
            result?.success(text)
            return
        }
        if (text.isNullOrEmpty()) return
        emitLog("Clipboard auto-read: ${text.length} chars; forwarding.")
        fanOut(mapOf("type" to "text", "text" to text))
    }

    private fun emitLog(message: String) {
        fanOut(mapOf("type" to "log", "message" to message))
    }

    private fun fanOut(payload: Map<String, Any?>) {
        if (sinks.isEmpty()) return
        mainHandler.post {
            for (sink in sinks) {
                try {
                    sink.success(payload)
                } catch (_: Exception) {
                    // A sink whose engine detached throws; drop it so it can't
                    // wedge future fan-outs.
                    sinks.remove(sink)
                }
            }
        }
    }
}
