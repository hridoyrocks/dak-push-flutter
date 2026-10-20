package io.github.hridoyrocks.dak_push

import android.Manifest
import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Resources
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.AdaptiveIconDrawable
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL

/** Shows Dak messages that Android's FCM cannot show itself (with buttons). */
object DakNotifier {
    const val EXTRA_DATA = "dak_push_data"
    const val EXTRA_ACTION = "dak_push_action"
    const val EXTRA_TAG = "dak_push_tag"
    const val EXTRA_ID = "dak_push_notification_id"

    private const val DEFAULT_CHANNEL = "dak_default"
    private const val FCM_CHANNEL = "fcm_fallback_notification_channel"
    private const val MAX_IMAGE_BYTES = 5 * 1024 * 1024

    data class Button(val id: String, val text: String)

    /** The FCM data of a message the SDK should show, or null. */
    fun dataToShow(extras: Bundle?): Map<String, String>? {
        if (extras == null || extras.getString("_dak_show") != "1") return null
        val data = HashMap<String, String>()
        for (key in extras.keySet()) {
            if (key.startsWith("google.") || key.startsWith("gcm.") || key == "from" || key == "collapse_key") continue
            val value = extras.get(key)
            if (value is String) data[key] = value
        }
        return data
    }

    /** Like firebase_messaging: an open, unlocked app gets messages itself. */
    fun isAppInForeground(context: Context): Boolean {
        val keyguard = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (keyguard.isKeyguardLocked) return false
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val processes = am.runningAppProcesses ?: return false
        return processes.any {
            it.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND && it.processName == context.packageName
        }
    }

    fun parseButtons(json: String?): List<Button> {
        if (json.isNullOrEmpty()) return emptyList()
        return try {
            val list = JSONArray(json)
            (0 until minOf(list.length(), 3)).mapNotNull { i ->
                val b = list.optJSONObject(i) ?: return@mapNotNull null
                val id = b.optString("id")
                val text = b.optString("text")
                if (id.isEmpty() || text.isEmpty()) null else Button(id, text)
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    /**
     * Builds and shows the notification; false when nothing was shown. Call it off the main thread: it may
     * download the image.
     */
    fun show(context: Context, data: Map<String, String>): Boolean {
        val title = data["_dak_title"].orEmpty()
        val body = data["_dak_body"].orEmpty()
        if (title.isEmpty() && body.isEmpty()) return false
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return false

        val tag = data["_dak_tag"]?.takeIf { it.isNotEmpty() } ?: data["_dak_id"] ?: "dak"
        val id = tag.hashCode()
        val builder = NotificationCompat.Builder(context, channel(context, data["_dak_channel"]))
            .setSmallIcon(smallIcon(context))
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(launch(context, data, null, tag, id, 0))
        color(context)?.let { builder.color = it }
        if (data["_dak_sound"] == "none") {
            builder.setSilent(true)
        } else {
            // Below Android 8 there are no channels: sound, light and vibration come from here.
            var defaults = NotificationCompat.DEFAULT_SOUND or NotificationCompat.DEFAULT_LIGHTS
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.VIBRATE) == PackageManager.PERMISSION_GRANTED) {
                defaults = defaults or NotificationCompat.DEFAULT_VIBRATE
            }
            builder.setDefaults(defaults)
        }
        data["_dak_badge_inc"]?.toIntOrNull()?.takeIf { it > 0 }?.let { builder.setNumber(it) }
        image(data["_dak_image"])?.let {
            builder.setLargeIcon(it)
            builder.setStyle(NotificationCompat.BigPictureStyle().bigPicture(it).bigLargeIcon(null as Bitmap?))
        }
        parseButtons(data["_dak_buttons"]).forEachIndexed { i, b ->
            builder.addAction(0, b.text, launch(context, data, b.id, tag, id, i + 1))
        }
        return try {
            manager.notify(tag, id, builder.build())
            true
        } catch (e: SecurityException) {
            // No POST_NOTIFICATIONS permission (Android 13+).
            false
        }
    }

    /** Opens the app with the message's data and the tapped button, which the plugin hands to Dart. */
    private fun launch(context: Context, data: Map<String, String>, action: String?, tag: String, id: Int, n: Int): PendingIntent {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: Intent()
        // CLEAR_TOP: with another of the app's activities on top (a camera, a login page), the tap still
        // reaches the Flutter activity (onNewIntent) instead of being lost.
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        intent.putExtra(EXTRA_DATA, Bundle().apply { data.forEach { (k, v) -> putString(k, v) } })
        intent.putExtra(EXTRA_TAG, tag)
        intent.putExtra(EXTRA_ID, id)
        if (action != null) intent.putExtra(EXTRA_ACTION, action)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(context, id * 4 + n, intent, flags)
    }

    private fun channel(context: Context, requested: String?): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return requested?.takeIf { it.isNotEmpty() } ?: DEFAULT_CHANNEL
        val nm = context.getSystemService(NotificationManager::class.java)
        val candidates = listOf(requested, meta(context)?.getString("com.google.firebase.messaging.default_notification_channel_id"), FCM_CHANNEL)
        for (c in candidates) {
            if (!c.isNullOrEmpty() && nm.getNotificationChannel(c) != null) return c
        }
        if (nm.getNotificationChannel(DEFAULT_CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(DEFAULT_CHANNEL, "Notifications", NotificationManager.IMPORTANCE_HIGH))
        }
        return DEFAULT_CHANNEL
    }

    private fun meta(context: Context): Bundle? = try {
        context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA).metaData
    } catch (e: Exception) {
        null
    }

    /** Like FCM: the manifest's default icon, else the app icon, else the system's; never an adaptive icon. */
    private fun smallIcon(context: Context): Int {
        val res = context.resources
        val icon = meta(context)?.getInt("com.google.firebase.messaging.default_notification_icon", 0) ?: 0
        if (icon != 0 && isValidIcon(res, icon)) return icon
        val app = context.applicationInfo.icon
        if (app != 0 && isValidIcon(res, app)) return app
        return android.R.drawable.sym_def_app_icon
    }

    /** Android 8.0 crashes the system UI on an adaptive icon as the small icon (FCM's isValidIcon). */
    private fun isValidIcon(res: Resources, id: Int): Boolean {
        if (Build.VERSION.SDK_INT != Build.VERSION_CODES.O) return true
        return try {
            res.getDrawable(id, null) !is AdaptiveIconDrawable
        } catch (e: Resources.NotFoundException) {
            false
        }
    }

    private fun color(context: Context): Int? {
        val res = meta(context)?.getInt("com.google.firebase.messaging.default_notification_color", 0) ?: 0
        return if (res == 0) null else try {
            ContextCompat.getColor(context, res)
        } catch (e: Exception) {
            null
        }
    }

    private fun image(url: String?): Bitmap? {
        if (url.isNullOrEmpty() || !url.startsWith("https://")) return null
        return try {
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.connectTimeout = 5000
            conn.readTimeout = 10000
            conn.instanceFollowRedirects = true
            try {
                if (conn.responseCode != 200) return null
                val out = ByteArrayOutputStream()
                val buf = ByteArray(16 * 1024)
                conn.inputStream.use { input ->
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        if (out.size() > MAX_IMAGE_BYTES) return null
                    }
                }
                val bytes = out.toByteArray()
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                var sample = 1
                while (bounds.outWidth / sample > 1440 || bounds.outHeight / sample > 1440) sample *= 2
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
            } finally {
                conn.disconnect()
            }
        } catch (e: Exception) {
            null
        }
    }
}
