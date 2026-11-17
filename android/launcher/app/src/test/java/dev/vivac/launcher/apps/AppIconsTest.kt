package dev.vivac.launcher.apps

import android.app.Application
import android.graphics.Color
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.ShapeDrawable
import android.graphics.drawable.shapes.OvalShape
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

    /** A foreground with a drawn shape: a small disc in the middle of the 108-unit layer, the rest transparent. */
    private fun drawn() = InsetDrawable(ShapeDrawable(OvalShape()).apply { paint.color = Color.WHITE }, 0.3f)

    @Test
    fun `without a themed layer, vivac makes one from the foreground's silhouette`() = runBlocking {
        val i = icons("drawn" to AdaptiveIconDrawable(ColorDrawable(Color.RED), drawn(), null))
        assertTrue(i.load("drawn") is AppIcon.Glyph)
    }

    @Test
    fun `a blank themed layer also falls back to the silhouette`() = runBlocking {
        val i = icons("blank" to AdaptiveIconDrawable(ColorDrawable(Color.RED), drawn(), ColorDrawable(Color.TRANSPARENT)))
        assertTrue(i.load("blank") is AppIcon.Glyph)
    }

    @Test
    fun `no colour icon ever shows, a solid foreground or a legacy icon gets the monogram`() = runBlocking {
        val i = icons("solid" to adaptive(null), "plain" to ColorDrawable(Color.BLUE), "empty" to AdaptiveIconDrawable(ColorDrawable(Color.RED), ColorDrawable(Color.TRANSPARENT), null))
        assertNull(i.load("solid"))
        assertNull(i.load("plain"))
        assertNull(i.load("empty"))
    }

    @Test
    fun `no icon is no icon, so the monogram shows`() = runBlocking {
        assertNull(icons().load("gone"))
    }

    @Test
    fun `icons are cached until forgotten`() = runBlocking {
        val i = icons("a" to adaptive(ColorDrawable(Color.BLACK)))
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
