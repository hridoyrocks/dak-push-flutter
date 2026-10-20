package io.github.hridoyrocks.dak_push

import android.content.Context
import java.security.SecureRandom

/**
 * A random nonce for every notification the SDK posts, kept in app-private
 * preferences. The launcher activity is exported, so any app can start it
 * with Dak's extras; only an intent with a nonce from here came from one of
 * our notifications. A nonce works once, so an intent the system replays
 * (the app restored after a low-memory kill) is not a second tap.
 */
internal object DakTaps {
    private const val PREFS = "dak_push_taps"
    private const val MAX = 200
    private const val MAX_AGE_MS = 30L * 24 * 60 * 60 * 1000
    private val random = SecureRandom()

    /** A new nonce for a notification about to be posted. Call it off the main thread: it writes to disk. */
    fun issue(context: Context): String {
        val bytes = ByteArray(16).also { random.nextBytes(it) }
        val nonce = bytes.joinToString("") { "%02x".format(it) }
        synchronized(this) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val now = System.currentTimeMillis()
            val edit = prefs.edit()
            // Old ones (notifications long gone or swiped away) make room.
            val kept = prefs.all.mapNotNull { (k, v) ->
                val at = v as? Long
                if (at == null || now - at > MAX_AGE_MS || at > now) {
                    edit.remove(k)
                    null
                } else {
                    k to at
                }
            }.sortedBy { it.second }
            kept.take(maxOf(0, kept.size - MAX + 1)).forEach { edit.remove(it.first) }
            edit.putLong(nonce, now)
            // Stored before the notification exists, even if the process dies right after.
            edit.commit()
        }
        return nonce
    }

    /** True once for a nonce [issue] gave; it is used up. */
    fun redeem(context: Context, nonce: String?): Boolean {
        if (nonce.isNullOrEmpty()) return false
        synchronized(this) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (!prefs.contains(nonce)) return false
            // On disk before the tap is handed on, so the intent replayed after a kill finds nothing.
            prefs.edit().remove(nonce).commit()
            return true
        }
    }
}
