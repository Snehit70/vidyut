package dev.snehit.vidyut.vidyut_clipboard

import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hosts the `vidyut/clipboard` MethodChannel from application context.
 *
 * As a plugin in GeneratedPluginRegistrant it attaches to every FlutterEngine —
 * the activity engine and the headless foreground-service engine alike — so the
 * service isolate can write the clipboard directly. Nothing here needs an
 * Activity: ClipboardManager, FileProvider.getUriForFile, and setPrimaryClip
 * all work from application context.
 */
class VidyutClipboardPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private lateinit var channel: MethodChannel
    private lateinit var screenOnChannel: EventChannel
    private lateinit var notificationsChannel: EventChannel
    private lateinit var context: Context
    private var screenOnListener: (() -> Unit)? = null
    private var notificationListener: ((Map<String, String>) -> Unit)? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "vidyut/clipboard")
        channel.setMethodCallHandler(this)
        screenOnChannel = EventChannel(binding.binaryMessenger, "vidyut/screen_on")
        screenOnChannel.setStreamHandler(this)
        notificationsChannel = EventChannel(binding.binaryMessenger, "vidyut/posted_notifications")
        notificationsChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                val listener: (Map<String, String>) -> Unit = { events.success(it) }
                notificationListener = listener
                PostedNotifications.addListener(listener)
            }

            override fun onCancel(arguments: Any?) {
                stopNotificationEvents()
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        screenOnChannel.setStreamHandler(null)
        notificationsChannel.setStreamHandler(null)
        onCancel(null)
        stopNotificationEvents()
    }

    private fun stopNotificationEvents() {
        notificationListener?.let { PostedNotifications.removeListener(it) }
        notificationListener = null
    }

    // Screen-on events (keepalive spec D5). Each engine's listen adds one
    // listener to the process-wide receiver; in practice only the service
    // isolate subscribes.
    override fun onListen(
        arguments: Any?,
        events: EventChannel.EventSink
    ) {
        val listener = { events.success(null) }
        screenOnListener = listener
        ScreenOnBroadcasts.addListener(context, listener)
    }

    override fun onCancel(arguments: Any?) {
        screenOnListener?.let { ScreenOnBroadcasts.removeListener(context, it) }
        screenOnListener = null
    }

    override fun onMethodCall(
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        when (call.method) {
            "writeText" -> {
                val text = call.argument<String>("text")
                val html = call.argument<String>("html")
                if (text == null) {
                    result.error("bad-args", "text is required", null)
                } else if (html != null) {
                    // Apps that paste formatting take the HTML; the rest take the text.
                    setPrimaryClip(result) { ClipData.newHtmlText("Vidyut text", text, html) }
                } else {
                    setPrimaryClip(result) { ClipData.newPlainText("Vidyut text", text) }
                }
            }
            "writeImage" -> {
                val path = call.argument<String>("path")
                val mime = call.argument<String>("mime")
                if (path == null || mime == null) {
                    result.error("bad-args", "path and mime are required", null)
                } else {
                    setPrimaryClip(result) { imageClip(File(path), mime) }
                }
            }
            "openClipboardPermissionSettings" -> {
                try {
                    openClipboardPermissionSettings()
                    result.success(null)
                } catch (error: Exception) {
                    result.error("open-settings", error.message, null)
                }
            }
            "hasNotificationAccess" -> result.success(
                NotificationManagerCompat.getEnabledListenerPackages(context)
                    .contains(context.packageName)
            )
            "openNotificationAccessSettings" -> {
                try {
                    openNotificationAccessSettings()
                    result.success(null)
                } catch (error: Exception) {
                    result.error("open-settings", error.message, null)
                }
            }
            "manufacturer" -> result.success(android.os.Build.MANUFACTURER)
            "openAutostartSettings" -> {
                try {
                    openAutostartSettings()
                    result.success(null)
                } catch (error: Exception) {
                    result.error("open-settings", error.message, null)
                }
            }
            "openBatterySaverSettings" -> {
                try {
                    openBatterySaverSettings()
                    result.success(null)
                } catch (error: Exception) {
                    result.error("open-settings", error.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    // MIUI's privacy layer rejects background writes with a SecurityException;
    // a distinct error code lets Dart tell "blocked by device policy" apart
    // from an ordinary write failure.
    private inline fun setPrimaryClip(
        result: MethodChannel.Result,
        clip: () -> ClipData
    ) {
        try {
            val manager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            manager.setPrimaryClip(clip())
            result.success(null)
        } catch (error: SecurityException) {
            result.error("clipboard-blocked", error.message, null)
        } catch (error: Exception) {
            result.error("clipboard-write", error.message, null)
        }
    }

    private fun imageClip(
        file: File,
        mime: String
    ): ClipData {
        require(file.exists()) { "Image file not found: ${file.path}" }
        // getUriForFile also rejects paths outside the provider's configured
        // vidyut_received/ subtree.
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        return ClipData(ClipDescription("Vidyut image", arrayOf(mime)), ClipData.Item(uri))
    }

    // Community-known MIUI permission editor (unverified upstream — keep the
    // fallback); resolves to the standard app-details screen elsewhere.
    private fun openClipboardPermissionSettings() {
        val editor = Intent("miui.intent.action.APP_PERM_EDITOR").apply {
            putExtra("extra_pkgname", context.packageName)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startResolvedOrFallback(editor)
    }

    // Community-known MIUI autostart manager (onboarding spec D5): the action
    // form first, then the security-center activity by component, then the
    // standard app-details screen.
    private fun openAutostartSettings() {
        val byAction = Intent("miui.intent.action.OP_AUTO_START").apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (byAction.resolveActivity(context.packageManager) != null) {
            context.startActivity(byAction)
            return
        }
        val byComponent = Intent().apply {
            component = android.content.ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity"
            )
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startResolvedOrFallback(byComponent)
    }

    // Community-known MIUI power-keeper per-app battery-saver page (D5);
    // app-details fallback elsewhere.
    private fun openBatterySaverSettings() {
        val powerKeeper = Intent().apply {
            component = android.content.ComponentName(
                "com.miui.powerkeeper",
                "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"
            )
            putExtra("package_name", context.packageName)
            putExtra("package_label", "Vidyut")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startResolvedOrFallback(powerKeeper)
    }

    // Straight to Vidyut's own switch where Android has that page (11+),
    // otherwise the list of apps with notification access.
    private fun openNotificationAccessSettings() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            val detail = Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS).apply {
                putExtra(
                    Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                    ComponentName(context, CodeNotificationListener::class.java).flattenToString()
                )
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            try {
                context.startActivity(detail)
                return
            } catch (_: ActivityNotFoundException) {
                // Some skins drop the detail page; the list below always exists.
            }
        }
        context.startActivity(
            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        )
    }

    private fun startResolvedOrFallback(preferred: Intent) {
        val intent = if (preferred.resolveActivity(context.packageManager) != null) {
            preferred
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", context.packageName, null)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }
        context.startActivity(intent)
    }
}

/**
 * Process-wide ACTION_SCREEN_ON fan-out (never plugin-instance state — both
 * engines instantiate the plugin). The receiver registers on the first
 * listener and unregisters on the last; onReceive runs on the main thread,
 * where EventChannel sinks must be called.
 */
internal object ScreenOnBroadcasts {
    private val listeners = mutableSetOf<() -> Unit>()
    private var receiver: BroadcastReceiver? = null

    @Synchronized
    fun addListener(
        context: Context,
        listener: () -> Unit
    ) {
        listeners.add(listener)
        if (receiver == null) {
            val screenOnReceiver = object : BroadcastReceiver() {
                override fun onReceive(
                    receiverContext: Context?,
                    intent: Intent?
                ) {
                    for (registered in snapshot()) registered()
                }
            }
            receiver = screenOnReceiver
            context.applicationContext.registerReceiver(
                screenOnReceiver,
                IntentFilter(Intent.ACTION_SCREEN_ON)
            )
        }
    }

    @Synchronized
    fun removeListener(
        context: Context,
        listener: () -> Unit
    ) {
        listeners.remove(listener)
        if (listeners.isEmpty()) {
            receiver?.let { context.applicationContext.unregisterReceiver(it) }
            receiver = null
        }
    }

    @Synchronized
    private fun snapshot(): List<() -> Unit> = listeners.toList()
}
