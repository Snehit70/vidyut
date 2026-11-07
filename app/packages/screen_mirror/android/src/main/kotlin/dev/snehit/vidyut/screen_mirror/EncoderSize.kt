package dev.snehit.vidyut.screen_mirror

import android.content.Context
import android.hardware.display.DisplayManager
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.DisplayMetrics
import android.view.Display
import kotlin.math.max
import kotlin.math.roundToInt

/** The size the screen is encoded at, and the density the virtual display uses. */
internal data class EncoderSize(val width: Int, val height: Int, val densityDpi: Int) {
    /** Enough bits for sharp text on a LAN; the relay window scales it up. */
    val bitRate: Int get() = (width.toLong() * height * 6).coerceIn(2_000_000L, 16_000_000L).toInt()

    companion object {
        /** The long side is capped here before the encoder's own limits apply. */
        private const val MAX_LONG_SIDE = 1920

        @Suppress("DEPRECATION")
        fun pick(context: Context): EncoderSize {
            val display = context.getSystemService(DisplayManager::class.java)
                .getDisplay(Display.DEFAULT_DISPLAY)
            val metrics = DisplayMetrics()
            display.getRealMetrics(metrics)
            val screenWidth = metrics.widthPixels
            val screenHeight = metrics.heightPixels

            val capabilities = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .firstOrNull { info ->
                    info.isEncoder && info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true) }
                }
                ?.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
                ?.videoCapabilities

            var scale = minOf(1.0, MAX_LONG_SIDE.toDouble() / max(screenWidth, screenHeight))
            while (true) {
                val width = align(screenWidth * scale)
                val height = align(screenHeight * scale)
                val fits = capabilities?.isSizeSupported(width, height) ?: true
                if (fits || scale < 0.2) {
                    val density = (metrics.densityDpi * width.toDouble() / screenWidth).roundToInt()
                    return EncoderSize(width, height, max(density, 120))
                }
                scale *= 0.9
            }
        }

        /** Whether the phone's screen is wider than it is tall right now. */
        @Suppress("DEPRECATION")
        fun isLandscape(context: Context): Boolean {
            val metrics = DisplayMetrics()
            context.getSystemService(DisplayManager::class.java)
                .getDisplay(Display.DEFAULT_DISPLAY)
                .getRealMetrics(metrics)
            return metrics.widthPixels > metrics.heightPixels
        }

        /** Encoders want sides that are multiples of 16. */
        private fun align(side: Double): Int = max(16, (side / 16).toInt() * 16)
    }
}
