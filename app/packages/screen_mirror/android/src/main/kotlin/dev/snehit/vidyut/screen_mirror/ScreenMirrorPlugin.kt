package dev.snehit.vidyut.screen_mirror

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Screen mirror for the Dart side (ADR 0030).
 *
 * `requestConsent` shows Android's capture prompt and keeps the grant;
 * `start` hands that grant, the stream URL and its key to
 * [ScreenMirrorService]. The grant is good for one start. State changes
 * arrive on the `vidyut/screen_mirror/state` event channel.
 */
class ScreenMirrorPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var binding: ActivityPluginBinding? = null
    private var pendingConsent: MethodChannel.Result? = null
    private var grantCode = 0
    private var grantData: Intent? = null
    private var listener: ((Map<String, Any>) -> Unit)? = null

    override fun onAttachedToEngine(flutter: FlutterPlugin.FlutterPluginBinding) {
        context = flutter.applicationContext
        methods = MethodChannel(flutter.binaryMessenger, "vidyut/screen_mirror")
        methods.setMethodCallHandler(this)
        events = EventChannel(flutter.binaryMessenger, "vidyut/screen_mirror/state")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(flutter: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        onCancel(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "encoderSize" -> {
                val size = EncoderSize.pick(context)
                result.success(mapOf("width" to size.width, "height" to size.height))
            }
            "isRunning" -> result.success(ScreenMirrorService.running)
            "requestConsent" -> requestConsent(result)
            "start" -> {
                val url = call.argument<String>("url")
                val key = call.argument<String>("key")
                val data = grantData
                if (url == null || key == null) {
                    result.error("bad_arguments", "start needs a url and a key", null)
                } else if (data == null) {
                    result.error("no_consent", "Screen capture was not allowed.", null)
                } else {
                    // A grant starts one projection, so it is used up here.
                    grantData = null
                    ScreenMirrorService.start(context, grantCode, data, url, key)
                    result.success(null)
                }
            }
            "stop" -> {
                grantData = null
                ScreenMirrorService.stop(context)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun requestConsent(result: MethodChannel.Result) {
        val activity: Activity? = binding?.activity
        if (activity == null) {
            result.error("no_activity", "Open Vidyut to mirror the screen.", null)
            return
        }
        if (pendingConsent != null) {
            result.error("busy", "The capture prompt is already open.", null)
            return
        }
        val manager = context.getSystemService(MediaProjectionManager::class.java)
        pendingConsent = result
        activity.startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_CONSENT)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CONSENT) return false
        val result = pendingConsent ?: return true
        pendingConsent = null
        if (resultCode == Activity.RESULT_OK && data != null) {
            grantCode = resultCode
            grantData = data
            result.success(true)
        } else {
            grantData = null
            result.success(false)
        }
        return true
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        // The app runs a second, headless engine; only the engine that
        // listens owns the service listener.
        val own: (Map<String, Any>) -> Unit = { event -> sink.success(event) }
        listener = own
        ScreenMirrorService.listener = own
    }

    override fun onCancel(arguments: Any?) {
        if (ScreenMirrorService.listener === listener) ScreenMirrorService.listener = null
        listener = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        binding?.removeActivityResultListener(this)
        binding = null
    }

    private companion object {
        const val REQUEST_CONSENT = 0x5C4E
    }
}
