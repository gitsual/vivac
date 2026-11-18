package dev.vivac.launcher.apps

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.provider.Settings

/**
 * Turns active notifications into notification dots. It reads only the package and flags of
 * each notification; titles and texts are never touched or stored.
 */
class DotsListener : NotificationListenerService() {
    override fun onListenerConnected() = recount()
    override fun onListenerDisconnected() = Dots.publish(emptySet())
    override fun onNotificationPosted(sbn: StatusBarNotification?) = recount()
    override fun onNotificationRemoved(sbn: StatusBarNotification?) = recount()

    private fun recount() {
        val ranking = currentRanking
        val notices = runCatching { activeNotifications.orEmpty() }.getOrDefault(emptyArray()).map { sbn ->
            val r = Ranking()
            val canBadge = ranking?.getRanking(sbn.key, r) != true || r.canShowBadge()
            Notice(
                packageName = sbn.packageName,
                ongoing = sbn.isOngoing,
                canShowBadge = canBadge,
                isGroupSummary = sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0,
            )
        }
        Dots.publish(Dots.of(notices), Dots.counts(notices))
    }

    companion object {
        /** Whether you granted vivac notification access in Settings. */
        fun isAllowed(context: Context): Boolean {
            val me = ComponentName(context, DotsListener::class.java).flattenToString()
            return Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners").orEmpty().split(":").contains(me)
        }
    }
}
