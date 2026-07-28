package dev.snehit.vidyut.clipboard_autosend

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle

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
    private var handled = false

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) readAndFinish()
    }

    private fun readAndFinish() {
        if (handled) return
        handled = true
        try {
            val manager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val text = manager.primaryClip
                ?.takeIf { it.itemCount > 0 }
                ?.getItemAt(0)
                ?.coerceToText(this)
                ?.toString()
            ClipboardAutoSendWatcher.onClipboardRead(
                text,
                manual = intent.getBooleanExtra(EXTRA_MANUAL_READ, false),
            )
        } finally {
            finish()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // No layout: the window is transparent and immediately hands focus back.
    }

    companion object {
        const val EXTRA_MANUAL_READ =
            "dev.snehit.vidyut.clipboard_autosend.extra.MANUAL_READ"
    }
}
