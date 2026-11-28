package dev.vivac.launcher.apps

import android.app.Notification
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import androidx.compose.ui.graphics.asImageBitmap
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import dev.vivac.launcher.avisos.Aviso
import dev.vivac.launcher.core.Notices
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Turns active notifications into notification dots, and into the notices vivac's own shade shows. Titles,
 * texts and pictures are kept only in memory, for the shade, while the notification is on the phone; vivac never
 * stores them.
 */
class DotsListener : NotificationListenerService() {
    override fun onListenerConnected() { connected = this; recount() }
    override fun onListenerDisconnected() {
        connected = null
        Dots.publish(emptySet())
        AndroidNotices.publish(emptyList())
        AndroidNotices.publishPlaying(null)
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
        // A notice Android has not touched keeps what was made of it: its pictures are not decoded again.
        made = active.associate { sbn -> sbn.key to (made[sbn.key]?.takeIf { it.first == sbn.postTime } ?: (sbn.postTime to aviso(sbn))) }
        AndroidNotices.publish(active.map { made.getValue(it.key).second })
        // What is playing: the first notification that carries a media session.
        val media = active.firstNotNullOfOrNull { sbn ->
            sbn.notification.extras.getParcelable(Notification.EXTRA_MEDIA_SESSION, android.media.session.MediaSession.Token::class.java)?.let { sbn to it }
        }
        controller = media?.let { (_, token) -> runCatching { android.media.session.MediaController(this, token) }.getOrNull() }
        AndroidNotices.publishPlaying(media?.let { (sbn, _) -> nowPlaying(sbn, controller) })
    }

    private var controller: android.media.session.MediaController? = null

    /** The session's own title and artist when it shares them; else the notification's. */
    private fun nowPlaying(sbn: StatusBarNotification, c: android.media.session.MediaController?): dev.vivac.launcher.core.NowPlaying {
        val meta = c?.metadata
        val extras = sbn.notification.extras
        return dev.vivac.launcher.core.NowPlaying(
            title = meta?.getString(android.media.MediaMetadata.METADATA_KEY_TITLE) ?: extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty(),
            artist = meta?.getString(android.media.MediaMetadata.METADATA_KEY_ARTIST) ?: extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty(),
            packageName = sbn.packageName,
            playing = c?.playbackState?.state == android.media.session.PlaybackState.STATE_PLAYING,
        )
    }

    internal fun media(command: dev.vivac.launcher.core.Media) {
        val controls = controller?.transportControls ?: return
        when (command) {
            dev.vivac.launcher.core.Media.PREVIOUS -> controls.skipToPrevious()
            dev.vivac.launcher.core.Media.NEXT -> controls.skipToNext()
            dev.vivac.launcher.core.Media.TOGGLE ->
                if (controller?.playbackState?.state == android.media.session.PlaybackState.STATE_PLAYING) controls.pause() else controls.play()
        }
    }

    private fun aviso(sbn: StatusBarNotification): Aviso {
        val n = sbn.notification
        val extras = n.extras
        return Aviso(
            key = sbn.key,
            packageName = sbn.packageName,
            title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty(),
            text = body(extras),
            postedAt = sbn.postTime,
            ongoing = sbn.isOngoing,
            clearable = sbn.isClearable,
            summary = n.flags and Notification.FLAG_GROUP_SUMMARY != 0,
            canReply = replyAction(n) != null,
            appLabel = runCatching { packageManager.getApplicationLabel(packageManager.getApplicationInfo(sbn.packageName, 0)).toString() }.getOrDefault(""),
            detail = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString().orEmpty(),
            avatar = image(n.getLargeIcon(), AVATAR_PX),
            picture = image(
                extras.getParcelable(Notification.EXTRA_PICTURE, android.graphics.Bitmap::class.java)?.let(android.graphics.drawable.Icon::createWithBitmap)
                    ?: extras.getParcelable(EXTRA_PICTURE_ICON, android.graphics.drawable.Icon::class.java),
                PICTURE_PX,
            ),
            actions = buttons(n).map { it.title.toString() },
        )
    }

    /**
     * What the notice says, as much of it as the app gives: a chat's last messages (who wrote each, in a group),
     * a list's lines, or the long text.
     */
    private fun body(extras: Bundle): String {
        val group = extras.getBoolean(Notification.EXTRA_IS_GROUP_CONVERSATION)
        val messages = extras.getParcelableArray(Notification.EXTRA_MESSAGES, android.os.Parcelable::class.java).orEmpty()
            .filterIsInstance<Bundle>().takeLast(MESSAGES).mapNotNull { m ->
                val said = m.getCharSequence("text")?.toString()?.takeIf { it.isNotBlank() }
                val who = (m.getParcelable("sender_person", android.app.Person::class.java)?.name ?: m.getCharSequence("sender"))?.toString()
                said?.let { if (group && !who.isNullOrBlank()) "$who: $it" else it }
            }
        val lines = messages.ifEmpty { extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES).orEmpty().map { it.toString() } }
        return lines.joinToString("\n").ifBlank {
            (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
        }
    }

    /** An icon as a picture no larger than [max] pixels on its long side; null when it cannot be read. */
    private fun image(icon: android.graphics.drawable.Icon?, max: Int): androidx.compose.ui.graphics.ImageBitmap? = runCatching {
        icon?.loadDrawable(this)?.let { drawable ->
            val scale = minOf(1f, max / maxOf(drawable.intrinsicWidth, drawable.intrinsicHeight, 1).toFloat())
            val width = (drawable.intrinsicWidth * scale).toInt().coerceAtLeast(1)
            val height = (drawable.intrinsicHeight * scale).toInt().coerceAtLeast(1)
            val bitmap = android.graphics.Bitmap.createBitmap(width, height, android.graphics.Bitmap.Config.ARGB_8888)
            drawable.setBounds(0, 0, width, height)
            drawable.draw(android.graphics.Canvas(bitmap))
            bitmap.asImageBitmap()
        }
    }.getOrNull()

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

    /** Presses one of the notification's own buttons. */
    internal fun act(key: String, index: Int) {
        val action = shown[key]?.notification?.let(::buttons)?.getOrNull(index) ?: return
        runCatching { action.actionIntent?.send() }
    }

    internal fun dismiss(key: String) { runCatching { cancelNotification(key) } }

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

    /** Each notice as last made, with when Android posted the notification it was made from. */
    private var made = emptyMap<String, Pair<Long, Aviso>>()

    companion object {
        /** The listener while Android keeps it connected; the shade acts through it. */
        @Volatile internal var connected: DotsListener? = null

        /** A notification's "reply" action: the one that takes free text. */
        private fun replyAction(n: Notification): Notification.Action? =
            n.actions?.firstOrNull { a -> a.remoteInputs?.any { it.allowFreeFormInput } == true }

        /** The app's own buttons: every action with a name that does not ask for written text. */
        private fun buttons(n: Notification): List<Notification.Action> =
            n.actions.orEmpty().filter { a -> a.remoteInputs.isNullOrEmpty() && !a.title.isNullOrBlank() }.take(BUTTONS)

        private const val BUTTONS = 3
        private const val MESSAGES = 6
        /** Long side, in pixels, of what the shade keeps of a picture: enough for its card, far less than a photo. */
        private const val AVATAR_PX = 96
        private const val PICTURE_PX = 720
        /** `Notification.EXTRA_PICTURE_ICON`, by name: how Android 12 and later carry a big picture that is not a bitmap. */
        private const val EXTRA_PICTURE_ICON = "android.pictureIcon"

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

    private val nowPlaying = MutableStateFlow<dev.vivac.launcher.core.NowPlaying?>(null)
    override val playing: StateFlow<dev.vivac.launcher.core.NowPlaying?> = nowPlaying.asStateFlow()
    internal fun publishPlaying(p: dev.vivac.launcher.core.NowPlaying?) { nowPlaying.value = p }
    override fun media(command: dev.vivac.launcher.core.Media) { DotsListener.connected?.media(command) }

    override fun open(key: String) { DotsListener.connected?.open(key) }
    override fun dismiss(key: String) { DotsListener.connected?.dismiss(key) }
    override fun act(key: String, index: Int) { DotsListener.connected?.act(key, index) }
    override fun reply(key: String, text: String): Boolean = DotsListener.connected?.reply(key, text) ?: false
    override fun quiet(): Boolean = DotsListener.connected?.quiet() ?: false
    override fun setQuiet(on: Boolean): Boolean = DotsListener.connected?.setQuiet(on) ?: false
}
