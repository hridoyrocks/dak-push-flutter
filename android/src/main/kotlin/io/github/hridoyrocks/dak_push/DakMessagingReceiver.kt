package io.github.hridoyrocks.dak_push

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Gets every FCM message, like firebase_messaging's receiver, and shows the
 * Dak messages sent as data so they can have buttons. Everything else (and
 * everything while the app is open) is left to firebase_messaging.
 */
class DakMessagingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val data = DakNotifier.dataToShow(intent.extras) ?: return
        if (DakNotifier.isAppInForeground(context)) return
        val pending = goAsync()
        Thread {
            try {
                DakNotifier.show(context.applicationContext, data)
            } finally {
                pending.finish()
            }
        }.start()
    }
}
