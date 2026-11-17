package dev.vivac.launcher.apps

import android.app.Application
import android.graphics.Color
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppIconsTest {
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val asked = mutableListOf<String>()
    private fun icons(vararg drawables: Pair<String, Drawable>) = AppIcons(app) { pkg -> asked += pkg; drawables.toMap()[pkg] }

    private fun adaptive(mono: Drawable?) = AdaptiveIconDrawable(ColorDrawable(Color.WHITE), ColorDrawable(Color.RED), mono)

    @Test
    fun `an app with a themed layer gets a glyph`() = runBlocking {
        assertTrue(icons("a" to adaptive(ColorDrawable(Color.BLACK))).load("a") is AppIcon.Glyph)
    }

    @Test
    fun `a blank themed layer, or none at all, falls back to the colour icon`() = runBlocking {
        val i = icons("blank" to adaptive(ColorDrawable(Color.TRANSPARENT)), "plain" to ColorDrawable(Color.BLUE), "old" to adaptive(null))
        assertTrue(i.load("blank") is AppIcon.Full)
        assertTrue(i.load("plain") is AppIcon.Full)
        assertTrue(i.load("old") is AppIcon.Full)
    }

    @Test
    fun `no icon is no icon, so the monogram shows`() = runBlocking {
        assertNull(icons().load("gone"))
    }

    @Test
    fun `icons are cached until forgotten`() = runBlocking {
        val i = icons("a" to ColorDrawable(Color.BLUE))
        i.load("a"); i.load("a")
        assertEquals(listOf("a"), asked)
        i.forget("a")
        i.load("a")
        assertEquals(listOf("a", "a"), asked)
    }

    @Test
    fun `the production lookup asks LauncherApps`() = runBlocking {
        assertNull(AppIcons(app).load("not.installed"))
    }
}
