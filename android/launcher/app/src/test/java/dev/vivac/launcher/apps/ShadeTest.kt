package dev.vivac.launcher.apps

import android.view.accessibility.AccessibilityEvent
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ShadeTest {
    private val titles = setOf("Notification shade.")
    private val state = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED

    @Test
    fun `Android's shade opening is told by its own pane title`() {
        assertTrue(Shade.opened(state, "com.android.systemui", 0, listOf("Notification shade."), titles))
        assertTrue(Shade.opened(state, "com.android.systemui", AccessibilityEvent.CONTENT_CHANGE_TYPE_PANE_APPEARED, listOf(" Notification shade. "), titles))
    }

    @Test
    fun `quick settings, other apps, other events and the shade closing are left alone`() {
        assertFalse(Shade.opened(state, "com.android.systemui", 0, listOf("Quick settings."), titles))
        assertFalse(Shade.opened(state, "com.android.systemui", 0, emptyList(), titles))
        assertFalse(Shade.opened(state, "org.example", 0, listOf("Notification shade."), titles))
        assertFalse(Shade.opened(state, null, 0, listOf("Notification shade."), titles))
        assertFalse(Shade.opened(AccessibilityEvent.TYPE_VIEW_CLICKED, "com.android.systemui", 0, listOf("Notification shade."), titles))
        assertFalse(Shade.opened(state, "com.android.systemui", AccessibilityEvent.CONTENT_CHANGE_TYPE_PANE_DISAPPEARED, listOf("Notification shade."), titles))
        assertFalse(Shade.opened(state, "com.android.systemui", 0, listOf("Notification shade."), emptySet()))
    }

    @Test
    fun `the titles come from the other app's own strings, in the phone's language`() {
        val app = ApplicationProvider.getApplicationContext<android.app.Application>()
        assertEquals(emptySet<String>(), Shade.titles(app))
        assertEquals(setOf(app.getString(dev.vivac.launcher.R.string.lock_service_label)), Shade.titles(app, app.packageName, listOf("lock_service_label", "no_such_string")))
    }
}
