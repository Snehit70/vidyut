package dev.snehit.vidyut.screen_mirror

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Base64
import android.util.Log
import android.view.Display
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Captures the screen and streams it to the laptop (ADR 0030).
 *
 * MediaProjection draws the screen into a hardware H.264 encoder. Each
 * encoded frame is sealed with the stream key and sent as one binary
 * WebSocket message. Frames wait in a short queue; when the network falls
 * behind, frames are dropped up to the next keyframe so the laptop never
 * shows a stale screen. The stream stops when the user taps Stop, revokes
 * the capture, or the laptop closes the window.
 */
class ScreenMirrorService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null

    // Set on the encoder thread, released from the main thread.
    @Volatile
    private var display: VirtualDisplay? = null

    @Volatile
    private var encoder: MediaCodec? = null

    @Volatile
    private var socket: MirrorSocket? = null
    private var worker: Thread? = null
    private var sender: Thread? = null

    @Volatile
    private var stopping = false

    // Set on the main thread when the phone turns; the encoder thread then
    // rebuilds the encoder at the new shape.
    @Volatile
    private var rotated = false
    private var displayListener: DisplayManager.DisplayListener? = null

    private val queue = ArrayBlockingQueue<Frame>(QUEUE_FRAMES)

    private class Frame(val bytes: ByteArray, val key: Boolean)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            finish("phone_stopped")
            return START_NOT_STICKY
        }
        if (projection != null || intent == null) return START_NOT_STICKY

        // Started with startForegroundService, so the service must go to the
        // foreground even to report a bad request. Android 14 also wants it
        // there before the token is turned into a projection.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification())
        }
        running = true

        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        val data = projectionData(intent)
        val url = intent.getStringExtra(EXTRA_URL)
        val key = try {
            intent.getStringExtra(EXTRA_KEY)?.let { Base64.decode(it, Base64.NO_WRAP) }
        } catch (_: IllegalArgumentException) {
            null
        }
        if (data == null || url == null || key == null || key.size != 32) {
            fail("The mirror request was incomplete.")
            return START_NOT_STICKY
        }

        val manager = getSystemService(MediaProjectionManager::class.java)
        val projection = try {
            manager.getMediaProjection(resultCode, data)
        } catch (error: RuntimeException) {
            null
        }
        if (projection == null) {
            fail("Android did not allow the screen capture.")
            return START_NOT_STICKY
        }
        this.projection = projection
        projection.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                finish("capture_revoked")
            }
        }, main)

        val size = EncoderSize.pick(this)
        watchRotation(size.width > size.height)
        worker = Thread({ stream(projection, size, url, key) }, "vidyut-mirror-encoder").apply { start() }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        release()
        running = false
        super.onDestroy()
    }

    private fun stream(projection: MediaProjection, first: EncoderSize, url: String, key: ByteArray) {
        val socket = MirrorSocket(url) { reason -> main.post { finish(reason) } }
        try {
            socket.connect(CONNECT_TIMEOUT_MS)
        } catch (error: Exception) {
            Log.w(TAG, "mirror connect failed", error)
            socket.close()
            main.post { fail("Could not reach the laptop to mirror the screen.") }
            return
        }
        this.socket = socket
        if (stopping) {
            // Stopped while connecting; release() ran before the socket existed.
            socket.close()
            return
        }

        // One encoder per screen shape. When the phone turns, the virtual
        // display moves to a fresh encoder of the new shape; the player picks
        // up the new size from the keyframe that follows.
        var size = first
        var codec: MediaCodec? = null
        var display: VirtualDisplay? = null
        var streaming = false
        try {
            while (!stopping) {
                val current = display
                if (current != null) {
                    current.setSurface(null)
                    codec?.let(::releaseCodec)
                    codec = null
                    this.encoder = null
                    current.resize(size.width, size.height, size.densityDpi)
                }
                val fresh = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
                codec = fresh
                fresh.configure(encoderFormat(size), null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                val surface = fresh.createInputSurface()
                fresh.start()
                this.encoder = fresh
                if (current == null) {
                    display = projection.createVirtualDisplay(
                        "vidyut-screen",
                        size.width,
                        size.height,
                        size.densityDpi,
                        DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                        surface,
                        null,
                        null,
                    )
                    this.display = display
                } else {
                    current.setSurface(surface)
                }
                if (stopping) break
                if (!streaming) {
                    streaming = true
                    sender = Thread({ send(socket, key) }, "vidyut-mirror-sender").apply { start() }
                    report(mapOf("state" to "streaming", "width" to size.width, "height" to size.height))
                }
                try {
                    drain(fresh)
                } catch (_: IllegalStateException) {
                    // The encoder was released by a stop.
                }
                if (!stopping && rotated) {
                    rotated = false
                    // Frames queued at the old shape would show at the wrong size.
                    queue.clear()
                    size = EncoderSize.pick(this)
                    Log.i(TAG, "screen turned; encoding at ${size.width}x${size.height}")
                }
            }
        } catch (error: Exception) {
            // A stop during setup also lands here, from the stopped projection.
            releaseLocal(display, codec, socket)
            if (!stopping) {
                Log.w(TAG, "mirror encoder failed", error)
                main.post { fail("This phone could not encode its screen.") }
            }
            return
        }
        if (stopping) {
            // Stopped while the encoder was set up; release() may have missed it.
            releaseLocal(display, codec, socket)
        }
    }

    private fun encoderFormat(size: EncoderSize): MediaFormat =
        MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, size.width, size.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, size.bitRate)
            setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            // A still screen produces no frames; repeat the last one so the
            // laptop window catches up after a drop.
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000L)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                setInteger(MediaFormat.KEY_PRIORITY, 0)
            }
        }

    private fun releaseCodec(codec: MediaCodec) {
        try {
            codec.stop()
        } catch (_: Exception) {
        }
        try {
            codec.release()
        } catch (_: Exception) {
        }
    }

    /** Flags a rebuild when the phone turns between portrait and landscape. */
    private fun watchRotation(startLandscape: Boolean) {
        var landscape = startLandscape
        val listener = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) {}

            override fun onDisplayRemoved(displayId: Int) {}

            override fun onDisplayChanged(displayId: Int) {
                if (displayId != Display.DEFAULT_DISPLAY || stopping) return
                val now = EncoderSize.isLandscape(this@ScreenMirrorService)
                if (now != landscape) {
                    landscape = now
                    rotated = true
                }
            }
        }
        getSystemService(DisplayManager::class.java).registerDisplayListener(listener, main)
        displayListener = listener
    }

    /** Releases what the encoder thread made. Safe to repeat after release(). */
    private fun releaseLocal(display: VirtualDisplay?, encoder: MediaCodec?, socket: MirrorSocket) {
        try {
            display?.release()
        } catch (_: Exception) {
        }
        try {
            encoder?.release()
        } catch (_: Exception) {
        }
        socket.close()
    }

    /** Moves encoded frames into the send queue, dropping to a keyframe when it is full. */
    private fun drain(encoder: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var config: ByteArray? = null
        var waitingForKeyframe = false
        while (!stopping && !rotated) {
            val index = try {
                encoder.dequeueOutputBuffer(info, 100_000L)
            } catch (_: IllegalStateException) {
                break
            }
            if (index < 0) continue
            val buffer: ByteBuffer? = encoder.getOutputBuffer(index)
            val bytes = ByteArray(info.size)
            if (buffer != null && info.size > 0) {
                buffer.position(info.offset)
                buffer.get(bytes, 0, info.size)
            }
            val flags = info.flags
            encoder.releaseOutputBuffer(index, false)
            if ((flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
            if (bytes.isEmpty()) continue

            if ((flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                config = bytes
                continue
            }
            val isKey = (flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
            if (isKey) {
                // The stream config rides on every keyframe, so the player can
                // start from any of them.
                val sps = config
                val frame = if (sps == null) bytes else sps + bytes
                if (!queue.offer(Frame(frame, true))) {
                    queue.clear()
                    queue.offer(Frame(frame, true))
                }
                waitingForKeyframe = false
            } else if (waitingForKeyframe) {
                continue
            } else if (!queue.offer(Frame(bytes, false))) {
                waitingForKeyframe = true
                requestKeyframe(encoder)
            }
        }
    }

    private fun requestKeyframe(encoder: MediaCodec) {
        try {
            encoder.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (_: IllegalStateException) {
        }
    }

    /** Seals frames in order and writes them to the socket. */
    private fun send(socket: MirrorSocket, key: ByteArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val secret = SecretKeySpec(key, "AES")
        val nonce = ByteArray(12)
        var counter = 0L
        try {
            while (!stopping) {
                val frame = queue.poll(250, TimeUnit.MILLISECONDS) ?: continue
                for (i in 0 until 8) nonce[4 + i] = (counter ushr (56 - 8 * i)).toByte()
                cipher.init(Cipher.ENCRYPT_MODE, secret, GCMParameterSpec(128, nonce))
                socket.sendBinary(cipher.doFinal(frame.bytes))
                counter += 1
            }
        } catch (_: InterruptedException) {
        } catch (error: Exception) {
            if (!stopping) {
                Log.w(TAG, "mirror send failed", error)
                main.post { finish("connection_lost") }
            }
        }
    }

    private fun fail(message: String) {
        report(mapOf("state" to "failed", "message" to message))
        finishQuietly()
    }

    private fun finish(reason: String) {
        if (stopping) return
        report(mapOf("state" to "stopped", "reason" to reason))
        finishQuietly()
    }

    private fun finishQuietly() {
        release()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun release() {
        if (stopping) return
        stopping = true
        running = false
        sender?.interrupt()
        displayListener?.let { getSystemService(DisplayManager::class.java).unregisterDisplayListener(it) }
        displayListener = null
        // Closing sends a close frame, which is network I/O.
        socket?.let { open -> Thread(open::close, "vidyut-mirror-close").start() }
        try {
            display?.release()
        } catch (_: Exception) {
        }
        try {
            encoder?.stop()
        } catch (_: Exception) {
        }
        try {
            encoder?.release()
        } catch (_: Exception) {
        }
        try {
            projection?.stop()
        } catch (_: Exception) {
        }
        queue.clear()
        display = null
        encoder = null
        projection = null
        socket = null
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Screen mirror", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while the screen is mirrored to the laptop."
                },
            )
        }
        val stop = PendingIntent.getService(
            this,
            0,
            Intent(this, ScreenMirrorService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(notificationIcon())
            .setContentTitle("Mirroring screen to the laptop")
            .setContentText("Everything on this screen shows on the laptop.")
            .setOngoing(true)
            .setContentIntent(launchIntent())
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
    }

    private fun launchIntent(): PendingIntent? {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        return PendingIntent.getActivity(this, 1, launch, PendingIntent.FLAG_IMMUTABLE)
    }

    /** The app's notification icon, which the plugin cannot reference directly. */
    private fun notificationIcon(): Int {
        val id = resources.getIdentifier("ic_notification", "drawable", packageName)
        return if (id != 0) id else android.R.drawable.ic_menu_view
    }

    companion object {
        private const val TAG = "VidyutScreenMirror"
        private const val CHANNEL_ID = "vidyut_screen_mirror"
        private const val NOTIFICATION_ID = 4130
        private const val QUEUE_FRAMES = 6
        private const val FRAME_RATE = 30
        private const val CONNECT_TIMEOUT_MS = 5_000
        private const val ACTION_STOP = "dev.snehit.vidyut.screen_mirror.STOP"
        internal const val EXTRA_RESULT_CODE = "resultCode"
        internal const val EXTRA_DATA = "data"
        internal const val EXTRA_URL = "url"
        internal const val EXTRA_KEY = "key"

        @Volatile
        var running = false
            private set

        /** Set by the plugin to hear state changes; called on the main thread. */
        @Volatile
        internal var listener: ((Map<String, Any>) -> Unit)? = null

        internal fun start(context: Context, resultCode: Int, data: Intent, url: String, key: String) {
            val intent = Intent(context, ScreenMirrorService::class.java)
                .putExtra(EXTRA_RESULT_CODE, resultCode)
                .putExtra(EXTRA_DATA, data)
                .putExtra(EXTRA_URL, url)
                .putExtra(EXTRA_KEY, key)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        internal fun stop(context: Context) {
            if (!running) return
            context.startService(Intent(context, ScreenMirrorService::class.java).setAction(ACTION_STOP))
        }

        private fun report(event: Map<String, Any>) {
            Handler(Looper.getMainLooper()).post { listener?.invoke(event) }
        }

        @Suppress("DEPRECATION")
        private fun projectionData(intent: Intent): Intent? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(EXTRA_DATA, Intent::class.java)
            } else {
                intent.getParcelableExtra(EXTRA_DATA)
            }
    }
}
