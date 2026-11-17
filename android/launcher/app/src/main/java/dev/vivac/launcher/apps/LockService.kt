package dev.vivac.launcher.apps

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent

/**
 * Turns the screen off when you double-tap the camp. It listens to no events and reads no window content:
 * Android only lets an accessibility service lock the screen, so this is the smallest one that can.
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
    }
}
