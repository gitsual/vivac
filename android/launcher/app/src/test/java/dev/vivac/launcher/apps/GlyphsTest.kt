package dev.vivac.launcher.apps

import android.graphics.RectF
import androidx.compose.ui.graphics.asAndroidPath
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.vivac.launcher.theme.Ink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GlyphsTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun `every glyph is drawable and stays inside the 24-unit grid`() {
        assertTrue(Glyphs.all.size >= 79)
        Glyphs.all.forEach { (pkg, d) ->
            val bounds = RectF()
            PathParser().parsePathString(d).toPath().asAndroidPath().computeBounds(bounds, true)
            assertTrue("$pkg is empty", bounds.width() > 0f || bounds.height() > 0f)
            assertTrue("$pkg leaves the grid: $bounds", bounds.left >= 0f && bounds.top >= 0f && bounds.right <= 24f && bounds.bottom <= 24f)
        }
    }

    @Test
    fun `apps vivac drew have a glyph, the rest do not`() {
        assertNotNull(Glyphs.of("com.termux"))
        assertNotNull(Glyphs.of("com.google.android.youtube"))
        assertNull(Glyphs.of("com.example.new"))
    }

    @Test
    fun `a tile shows the glyph when there is one, and the monogram otherwise`() {
        compose.setContent {
            AppFace(InstalledApp("Termux", "com.termux", false), Ink.ok)
            AppFace(InstalledApp("Zeta Nueva", "com.example.new", false), Ink.text)
        }
        compose.onNodeWithText(">_").assertDoesNotExist()
        compose.onNodeWithText("Zn").assertExists()
    }

    @Test
    fun `every app on the phone that still showed a monogram has its glyph`() {
        listOf(
            "com.gaurav.avnc", "com.starbucks.es", "com.termux.widget", "com.termux.x11",
            "dev.vivac.launcher", "org.kde.kdeconnect_tp", "org.localsend.localsend_app",
        ).forEach { assertNotNull(it, Glyphs.of(it)) }
    }
}
