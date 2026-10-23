package dev.snehit.vidyut.vidyut_clipboard

import android.app.Notification
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Hands posted notifications to the verification-code forwarder. Android binds
 * this once the user grants notification access; it forwards nothing until the
 * service isolate subscribes, and only notifications with a digit in them, so
 * the rest of the shade never crosses into Dart.
 */
class CodeNotificationListener : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return
        val notification = sbn.notification ?: return
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = notification.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val body = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
        if ((title + body).none { it.isDigit() }) return
        PostedNotifications.publish(
            mapOf("packageName" to sbn.packageName, "title" to title, "text" to body)
        )
    }
}

/**
 * Process-wide fan-out from [CodeNotificationListener] to EventChannel sinks,
 * like [ScreenOnBroadcasts]. Sinks must be called on the main thread.
 */
internal object PostedNotifications {
    private val listeners = mutableSetOf<(Map<String, String>) -> Unit>()
    private val mainThread = Handler(Looper.getMainLooper())

    @Synchronized
    fun addListener(listener: (Map<String, String>) -> Unit) {
        listeners.add(listener)
    }

    @Synchronized
    fun removeListener(listener: (Map<String, String>) -> Unit) {
        listeners.remove(listener)
    }

    fun publish(notification: Map<String, String>) {
        val targets = snapshot()
        if (targets.isEmpty()) return
        mainThread.post { for (target in targets) target(notification) }
    }

    @Synchronized
    private fun snapshot(): List<(Map<String, String>) -> Unit> = listeners.toList()
}
