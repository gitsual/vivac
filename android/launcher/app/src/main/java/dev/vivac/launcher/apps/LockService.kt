package dev.vivac.launcher.apps

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent

/**
 * Turns the screen off when you double-tap the camp, and runs the global actions a gesture asks for (recent apps,
 * quick settings, power menu, screenshot). It listens to no events and reads no window content: Android only lets
 * an accessibility service do these, so this is the smallest one that can.
 */
class LockService : AccessibilityService() {
    override fun onServiceConnected() { current = this }
    override fun onUnbind(intent: android.content.Intent?): Boolean {
        if (current === this) current = null
        return super.onUnbind(intent)
    }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit
    override fun onInterrupt() = Unit

    companion object {
        private var current: LockService? = null
        val running: Boolean get() = current != null

        /** False when you have not switched the service on in Accessibility. */
        fun lock(): Boolean = current?.performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN) ?: false

        /** Recent apps, quick settings, the power menu or a screenshot; false when the service is off. */
        fun perform(action: dev.vivac.launcher.core.GlobalAction): Boolean = current?.performGlobalAction(code(action)) ?: false

        fun code(action: dev.vivac.launcher.core.GlobalAction): Int = when (action) {
            dev.vivac.launcher.core.GlobalAction.RECENTS -> GLOBAL_ACTION_RECENTS
            dev.vivac.launcher.core.GlobalAction.QUICK_SETTINGS -> GLOBAL_ACTION_QUICK_SETTINGS
            dev.vivac.launcher.core.GlobalAction.POWER -> GLOBAL_ACTION_POWER_DIALOG
            dev.vivac.launcher.core.GlobalAction.SCREENSHOT -> GLOBAL_ACTION_TAKE_SCREENSHOT
        }
    }
}
