package dev.vivac.launcher.apps

import android.content.Context
import android.view.accessibility.AccessibilityEvent

/**
 * Tells when Android's notification shade has just opened, so vivac's Avisos can take its place. Android announces
 * the shade with a pane title in the phone's language; the titles are read from SystemUI's own strings, so nothing
 * on screen is ever read. Quick settings carry another title and are left alone.
 */
object Shade {
    const val SYSTEM_UI = "com.android.systemui"
    private val KEYS = listOf("accessibility_desc_notification_shade", "accessibility_desc_qs_notification_shade")

    fun opened(type: Int, pkg: CharSequence?, changes: Int, text: List<CharSequence>, titles: Set<String>): Boolean =
        type == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            pkg?.toString() == SYSTEM_UI &&
            changes and AccessibilityEvent.CONTENT_CHANGE_TYPE_PANE_DISAPPEARED == 0 &&
            text.any { it.toString().trim() in titles }

    /** What [pkg] calls its shade right now; empty when it cannot be read, and then nothing is ever replaced. */
    fun titles(context: Context, pkg: String = SYSTEM_UI, keys: List<String> = KEYS): Set<String> = runCatching {
        val res = context.packageManager.getResourcesForApplication(pkg)
        keys.mapNotNull { key -> res.getIdentifier(key, "string", pkg).takeIf { it != 0 }?.let(res::getString)?.trim() }.toSet()
    }.getOrDefault(emptySet())
}
