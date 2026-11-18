package dev.vivac.launcher.apps

import android.app.Notification
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import dev.vivac.launcher.avisos.Aviso
import dev.vivac.launcher.core.Notices
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Turns active notifications into notification dots, and into the notices vivac's own shade shows. Titles and
 * texts are kept only in memory, for the shade, while the notification is on the phone; vivac never stores them.
 */
class DotsListener : NotificationListenerService() {
    override fun onListenerConnected() { connected = this; recount() }
    override fun onListenerDisconnected() {
        connected = null
        Dots.publish(emptySet())
        AndroidNotices.publish(emptyList())
    }
    override fun onNotificationPosted(sbn: StatusBarNotification?) = recount()
    override fun onNotificationRemoved(sbn: StatusBarNotification?) = recount()

    private fun recount() {
        val ranking = currentRanking
        val active = runCatching { activeNotifications.orEmpty() }.getOrDefault(emptyArray())
        val notices = active.map { sbn ->
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
        shown = active.associateBy { it.key }
        AndroidNotices.publish(active.map(::aviso))
    }

    private fun aviso(sbn: StatusBarNotification): Aviso {
        val n = sbn.notification
        val extras = n.extras
        return Aviso(
            key = sbn.key,
            packageName = sbn.packageName,
            title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty(),
            text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty(),
            postedAt = sbn.postTime,
            ongoing = sbn.isOngoing,
            clearable = sbn.isClearable,
            summary = n.flags and Notification.FLAG_GROUP_SUMMARY != 0,
            canReply = replyAction(n) != null,
        )
    }

    /** What the shade's buttons do, on the notification Android still holds under [key]. */
    internal fun open(key: String) {
        val sbn = shown[key] ?: return
        // The launcher is on screen, so it may start the app; since Android 14 the sender has to say so.
        @Suppress("DEPRECATION")
        val options = if (android.os.Build.VERSION.SDK_INT >= 34) {
            android.app.ActivityOptions.makeBasic()
                .setPendingIntentBackgroundActivityStartMode(android.app.ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
                .toBundle()
        } else null
        runCatching { sbn.notification.contentIntent?.send(this, 0, null, null, null, null, options) }
        if (sbn.notification.flags and Notification.FLAG_AUTO_CANCEL != 0) runCatching { cancelNotification(key) }
    }

    internal fun dismiss(key: String) { runCatching { cancelNotification(key) } }

    internal fun dismissAll() { runCatching { cancelAllNotifications() } }

    internal fun quiet(): Boolean = runCatching { currentInterruptionFilter }.getOrDefault(INTERRUPTION_FILTER_ALL).let {
        it != INTERRUPTION_FILTER_ALL && it != INTERRUPTION_FILTER_UNKNOWN
    }

    internal fun setQuiet(on: Boolean): Boolean =
        runCatching { requestInterruptionFilter(if (on) INTERRUPTION_FILTER_PRIORITY else INTERRUPTION_FILTER_ALL) }.isSuccess

    internal fun reply(key: String, text: String): Boolean {
        val action = shown[key]?.notification?.let(::replyAction) ?: return false
        val inputs = action.remoteInputs ?: return false
        val fill = Intent()
        RemoteInput.addResultsToIntent(inputs, fill, Bundle().apply { inputs.forEach { putCharSequence(it.resultKey, text) } })
        return runCatching { action.actionIntent.send(this, 0, fill) }.isSuccess
    }

    private var shown = emptyMap<String, StatusBarNotification>()

    companion object {
        /** The listener while Android keeps it connected; the shade acts through it. */
        @Volatile internal var connected: DotsListener? = null

        /** A notification's "reply" action: the one that takes free text. */
        private fun replyAction(n: Notification): Notification.Action? =
            n.actions?.firstOrNull { a -> a.remoteInputs?.any { it.allowFreeFormInput } == true }

        /** Whether you granted vivac notification access in Settings. */
        fun isAllowed(context: Context): Boolean {
            val me = ComponentName(context, DotsListener::class.java).flattenToString()
            return Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners").orEmpty().split(":").contains(me)
        }
    }
}

/** Adapter: the shade's notices, from the connected [DotsListener]. */
object AndroidNotices : Notices {
    private val current = MutableStateFlow(emptyList<Aviso>())
    override val live: StateFlow<List<Aviso>> = current.asStateFlow()

    internal fun publish(avisos: List<Aviso>) { current.value = avisos }

    override fun open(key: String) { DotsListener.connected?.open(key) }
    override fun dismiss(key: String) { DotsListener.connected?.dismiss(key) }
    override fun dismissAll() { DotsListener.connected?.dismissAll() }
    override fun reply(key: String, text: String): Boolean = DotsListener.connected?.reply(key, text) ?: false
    override fun quiet(): Boolean = DotsListener.connected?.quiet() ?: false
    override fun setQuiet(on: Boolean): Boolean = DotsListener.connected?.setQuiet(on) ?: false
}
