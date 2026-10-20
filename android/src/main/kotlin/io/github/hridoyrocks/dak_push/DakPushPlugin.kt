package io.github.hridoyrocks.dak_push

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File

/** Hands taps on notifications the SDK showed (with the button id) to Dart. */
class DakPushPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware, PluginRegistry.NewIntentListener {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var binding: ActivityPluginBinding? = null
    private var initial: Map<String, Any?>? = null
    private var initialRead = false
    private val main = Handler(Looper.getMainLooper())

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
        // With a cached engine Dart may have asked for the launch tap before any activity existed, and an
        // activity can come and go while the engine lives on: a tap that starts an activity after Dart read
        // the initial one goes to Dart as a tap.
        val tap = take(b.activity, b.activity.intent) ?: return
        if (initialRead) {
            channel?.invokeMethod("onAction", tap)
        } else if (initial == null) {
            initial = tap
        }
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

    /** Reads a tap from an intent once, and closes the notification after a button tap. */
    private fun take(activity: Activity?, intent: Intent?): Map<String, Any?>? {
        if (intent == null || (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return null
        val bundle = intent.getBundleExtra(DakNotifier.EXTRA_DATA) ?: return null
        val data = HashMap<String, String>()
        for (k in bundle.keySet()) bundle.getString(k)?.let { data[k] = it }
        val action = intent.getStringExtra(DakNotifier.EXTRA_ACTION)
        if (action != null) {
            val ctx = activity ?: context
            ctx?.let { NotificationManagerCompat.from(it).cancel(intent.getStringExtra(DakNotifier.EXTRA_TAG), intent.getIntExtra(DakNotifier.EXTRA_ID, 0)) }
        }
        intent.removeExtra(DakNotifier.EXTRA_DATA)
        intent.removeExtra(DakNotifier.EXTRA_ACTION)
        return mapOf("data" to data, "action_id" to action)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialAction" -> {
                result.success(if (initialRead) null else initial)
                initialRead = true
                initial = null
            }
            "show" -> {
                val ctx = context
                val data = call.argument<Map<String, String>>("data")
                if (ctx == null || data == null) {
                    result.success(false)
                    return
                }
                Thread {
                    val shown = try {
                        DakNotifier.show(ctx, data)
                    } catch (e: Throwable) {
                        false
                    }
                    main.post { result.success(shown) }
                }.start()
            }
            // Kept out of backups (a restored copy would belong to another install) and deleted with the app.
            "storageDirectory" -> {
                val dir = context?.let { File(it.noBackupFilesDir, "dak_push") }
                result.success(if (dir != null && (dir.isDirectory || dir.mkdirs())) dir.absolutePath else null)
            }
            "extensionReceipts" -> result.success(emptyList<String>())
            // iOS only.
            "takeAction", "shareWithExtension", "setBadge", "removeExtensionReceipts" -> result.success(null)
            else -> result.notImplemented()
        }
    }
}
