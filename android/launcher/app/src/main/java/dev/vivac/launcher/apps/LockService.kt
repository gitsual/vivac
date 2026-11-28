package dev.vivac.launcher.apps

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import dev.vivac.launcher.MainActivity
import dev.vivac.launcher.core.GlobalAction
import dev.vivac.launcher.core.Launcher

/**
 * Turns the screen off when you double-tap the camp, and runs the global actions a gesture asks for (recent apps,
 * quick settings, power menu, screenshot). If you choose it, it also closes Android's notification shade as it
 * opens and shows vivac's Avisos instead. It reads no window content: the only events it hears are SystemUI's
 * window changes, and of those only the shade's own title.
 */
class LockService : AccessibilityService() {
    override fun onServiceConnected() { current = this }
    override fun onUnbind(intent: Intent?): Boolean {
        if (current === this) current = null
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null || event.packageName?.toString() != Shade.SYSTEM_UI || !ownShade()) return
        if (!Shade.opened(event.eventType, event.packageName, event.contentChangeTypes, event.text, titles(this))) return
        performGlobalAction(GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE)
        startActivity(Intent(MainActivity.ACTION_OPEN_AVISOS).setClass(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /** Chosen in settings, with Avisos able to show notices, the phone unlocked, and no shade vivac itself asked for. */
    private fun ownShade(): Boolean =
        SystemClock.uptimeMillis() >= quietUntil &&
            getSharedPreferences("home", Context.MODE_PRIVATE).getString(Launcher.KEY_OWN_SHADE, null) == "1" &&
            DotsListener.isAllowed(this) &&
            !getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked

    override fun onInterrupt() = Unit

    companion object {
        private const val QUIET_MS = 2_000L
        private var current: LockService? = null
        private var quietUntil = 0L
        val running: Boolean get() = current != null

        /** What SystemUI calls its shade; replaced in tests. */
        var titles: (Context) -> Set<String> = Shade::titles

        /** vivac is about to open Android's shade on purpose: leave it alone for a moment. */
        fun letShade() { quietUntil = SystemClock.uptimeMillis() + QUIET_MS }

        /** False when you have not switched the service on in Accessibility. */
        fun lock(): Boolean = current?.performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN) ?: false

        /** Recent apps, quick settings, the power menu or a screenshot; false when the service is off. */
        fun perform(action: GlobalAction): Boolean {
            if (action == GlobalAction.QUICK_SETTINGS) letShade()
            return current?.performGlobalAction(code(action)) ?: false
        }

        fun code(action: GlobalAction): Int = when (action) {
            GlobalAction.RECENTS -> GLOBAL_ACTION_RECENTS
            GlobalAction.QUICK_SETTINGS -> GLOBAL_ACTION_QUICK_SETTINGS
            GlobalAction.POWER -> GLOBAL_ACTION_POWER_DIALOG
            GlobalAction.SCREENSHOT -> GLOBAL_ACTION_TAKE_SCREENSHOT
        }
    }
}
