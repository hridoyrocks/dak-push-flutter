package io.github.hridoyrocks.dak_push

import android.app.Activity
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/** Hands taps on notifications the SDK showed (with the button id) to Dart. */
class DakPushPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware, PluginRegistry.NewIntentListener {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var binding: ActivityPluginBinding? = null
    private var initial: Map<String, Any?>? = null
    private var initialRead = false

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        context = b.applicationContext
        channel = MethodChannel(b.binaryMessenger, "dak_push").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onAttachedToActivity(b: ActivityPluginBinding) {
        binding = b
        b.addOnNewIntentListener(this)
        if (!initialRead && initial == null) initial = take(b.activity, b.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = onAttachedToActivity(b)

    override fun onDetachedFromActivity() {
        binding?.removeOnNewIntentListener(this)
        binding = null
    }

    override fun onNewIntent(intent: Intent): Boolean {
        val tap = take(binding?.activity, intent) ?: return false
        channel?.invokeMethod("onAction", tap)
        return false
    }

    /**
     * Reads a tap from an intent once, and closes the notification after a button tap. Only an intent
     * from a notification the SDK posted counts: the launcher activity is exported, so any app can
     * start it with these extras, and the system replays the intent when it restores the app.
     */
    private fun take(activity: Activity?, intent: Intent?): Map<String, Any?>? {
        if (intent == null || (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return null
        val ctx = activity ?: context ?: return null
        return try {
            val bundle = intent.getBundleExtra(DakNotifier.EXTRA_DATA) ?: return null
            val nonce = intent.getStringExtra(DakNotifier.EXTRA_NONCE)
            val action = intent.getStringExtra(DakNotifier.EXTRA_ACTION)
            val tag = intent.getStringExtra(DakNotifier.EXTRA_TAG)
            val id = intent.getIntExtra(DakNotifier.EXTRA_ID, 0)
            for (extra in listOf(DakNotifier.EXTRA_DATA, DakNotifier.EXTRA_ACTION, DakNotifier.EXTRA_NONCE, DakNotifier.EXTRA_TAG, DakNotifier.EXTRA_ID)) {
                intent.removeExtra(extra)
            }
            if (!DakTaps.redeem(ctx, nonce)) return null
            val data = HashMap<String, String>()
            for (k in bundle.keySet()) bundle.getString(k)?.let { data[k] = it }
            if (action != null) NotificationManagerCompat.from(ctx).cancel(tag, id)
            mapOf("data" to data, "action_id" to action)
        } catch (e: RuntimeException) {
            // Extras another app made unreadable on purpose.
            null
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialAction" -> {
                result.success(if (initialRead) null else initial)
                initialRead = true
            }
            "show" -> {
                val ctx = context
                val data = call.argument<Map<String, String>>("data")
                if (ctx != null && data != null && data["_dak_show"] == "1") {
                    // show() never throws.
                    Thread { DakNotifier.show(ctx, data) }.start()
                }
                result.success(null)
            }
            // iOS only.
            "takeAction", "shareWithExtension", "setBadge" -> result.success(null)
            else -> result.notImplemented()
        }
    }
}
