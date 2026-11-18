package dev.vivac.launcher.apps

import android.content.ComponentName
import android.content.Intent
import android.graphics.RectF
import android.os.Bundle
import android.os.Message

/**
 * Android's swipe-home handshake with the home app (Launcher3's GestureNavContract, undocumented but stable
 * since Android 11): the home intent carries which app is closing and a callback; the home app answers with
 * where that app's icon is, and the closing window shrinks into it. An empty answer keeps the plain animation.
 */
class GestureContract private constructor(val packageName: String, private val callback: Message) {

    /** Answers with the icon's place in screen pixels (empty: no icon on screen). */
    fun reply(position: RectF) {
        val answer = Message.obtain().apply {
            copyFrom(this@GestureContract.callback)
            data = Bundle().apply { putParcelable(EXTRA_ICON_POSITION, position) }
        }
        runCatching { answer.replyTo.send(answer) }
    }

    companion object {
        const val EXTRA_GESTURE_CONTRACT = "gesture_nav_contract_v1"
        const val EXTRA_ICON_POSITION = "gesture_nav_contract_icon_position"
        const val EXTRA_REMOTE_CALLBACK = "android.intent.extra.REMOTE_CALLBACK"
        const val EXTRA_ENABLE = "gesture_nav_contract_enable"

        /** The handshake in a home intent, taken out of it so it is answered once; null if absent or off. */
        @Suppress("DEPRECATION")
        fun from(intent: Intent): GestureContract? {
            val extras = intent.getBundleExtra(EXTRA_GESTURE_CONTRACT) ?: return null
            intent.removeExtra(EXTRA_GESTURE_CONTRACT)
            if (!extras.getBoolean(EXTRA_ENABLE, true)) return null
            val component = extras.getParcelable<ComponentName>(Intent.EXTRA_COMPONENT_NAME) ?: return null
            val callback = extras.getParcelable<Message>(EXTRA_REMOTE_CALLBACK)?.takeIf { it.replyTo != null } ?: return null
            return GestureContract(component.packageName, callback)
        }
    }
}
