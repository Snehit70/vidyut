package dev.snehit.vidyut.clipboard_autosend

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper

/**
 * Invisible, input-less focus-stealer (read-logs-auto-text D5). Launched on a
 * ClipboardService denial, it takes focus for an instant, reads the clipboard in
 * [onWindowFocusChanged] — now permitted, it is the focused app — forwards the
 * text through [ClipboardAutoSendWatcher.onClipboardRead], and finishes.
 *
 * Manifest (in the plugin AndroidManifest): translucent theme, excludeFromRecents,
 * noHistory, not exported, singleInstance — "invisible and doesn't require any
 * interaction from the user" (KDE's ClipboardFloatingActivity).
 */
class ClipboardReadActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private var handled = false
    private var manualRequestId: Long? = null
    private val focusTimeout = Runnable {
        val requestId = manualRequestId ?: return@Runnable
        if (handled) return@Runnable
        handled = true
        ClipboardAutoSendWatcher.completeManualRead(
            requestId,
            status = "focusTimeout",
        )
        finish()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) readAndFinish()
    }

    private fun readAndFinish() {
        if (handled) return
        handled = true
        handler.removeCallbacks(focusTimeout)
        try {
            val manager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val text = manager.primaryClip
                ?.takeIf { it.itemCount > 0 }
                ?.getItemAt(0)
                ?.coerceToText(this)
                ?.toString()
            val requestId = manualRequestId
            if (requestId == null) {
                ClipboardAutoSendWatcher.onClipboardRead(text)
            } else {
                ClipboardAutoSendWatcher.completeManualRead(
                    requestId,
                    status = if (text.isNullOrBlank()) "empty" else "text",
                    text = text?.takeUnless { it.isBlank() },
                )
            }
        } catch (_: Exception) {
            manualRequestId?.let {
                ClipboardAutoSendWatcher.completeManualRead(
                    it,
                    status = "unreadable",
                )
            }
        } finally {
            finish()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent.getBooleanExtra(EXTRA_MANUAL_READ, false)) {
            val requestId = ClipboardAutoSendWatcher.beginManualRead()
            if (requestId == null) {
                ClipboardAutoSendWatcher.reportManualBusy()
                finish()
                return
            }
            manualRequestId = requestId
            ClipboardAutoSendWatcher.updateNotification(
                this,
                "Vidyut sending",
                "Reading copied text...",
            )
            handler.postDelayed(focusTimeout, MANUAL_FOCUS_TIMEOUT_MS)
        }
        // No layout: the window is transparent and immediately hands focus back.
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra(EXTRA_MANUAL_READ, false)) {
            ClipboardAutoSendWatcher.reportManualBusy()
        }
    }

    override fun onDestroy() {
        handler.removeCallbacks(focusTimeout)
        if (!handled) {
            handled = true
            manualRequestId?.let {
                ClipboardAutoSendWatcher.completeManualRead(
                    it,
                    status = "unreadable",
                )
            }
        }
        super.onDestroy()
    }

    companion object {
        private const val MANUAL_FOCUS_TIMEOUT_MS = 2_000L
        const val EXTRA_MANUAL_READ =
            "dev.snehit.vidyut.clipboard_autosend.extra.MANUAL_READ"
    }
}
