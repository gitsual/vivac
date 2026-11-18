package dev.vivac.launcher.apps

import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.ResolveInfo
import android.graphics.Color
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.ColorDrawable
import android.os.Process
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.vivac.launcher.core.IconPackInfo
import dev.vivac.launcher.core.IconStyle
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onNodeWithTag
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf

@RunWith(AndroidJUnit4::class)
class AppIconsTest {
    @get:org.junit.Rule val compose = androidx.compose.ui.test.junit4.createComposeRule()

    private fun show(style: IconStyle, appIcon: android.graphics.drawable.Drawable) {
        val i = icons(appIcon = appIcon)
        compose.setContent {
            androidx.compose.runtime.CompositionLocalProvider(LocalAppIcons provides i, LocalIconChoice provides IconChoice(style)) {
                AppFace(InstalledApp("Signal", "org.signal", false), androidx.compose.ui.graphics.Color.Green)
            }
        }
        compose.waitForIdle()
    }

    @Test
    fun `a tile draws the app's own icon, and a themed one tinted, instead of the glyph`() {
        show(IconStyle.ORIGINAL, ColorDrawable(Color.RED))
        compose.onNodeWithTag("icon:image", useUnmergedTree = true).assertExists()
    }

    @Test
    fun `an app's own choice wins over the general style`() = runBlocking {
        val i = icons()
        assertNull(i.load("org.signal", IconChoice(IconStyle.ORIGINAL), dev.vivac.launcher.core.IconOverride.Glyph))
        assertNotNull(i.load("org.signal", IconChoice(IconStyle.GLYPHS), dev.vivac.launcher.core.IconOverride.App))
        assertNotNull(i.load("org.signal", IconChoice(IconStyle.GLYPHS), dev.vivac.launcher.core.IconOverride.Pack("a.pack", "terminal")))
        assertEquals(listOf("signal"), i.packIcons("a.pack"))
        assertSame(i.packIcon("a.pack", "terminal"), i.packIcon("a.pack", "terminal"))
    }

    @Test
    fun `a pack's icons are picked from a searchable grid`() {
        val i = icons(filter = mapOf("a/b" to "terminal", "c/d" to "maps", "e/f" to "maps_alt"))
        var picked: dev.vivac.launcher.core.IconOverride? = null
        compose.setContent {
            androidx.compose.runtime.CompositionLocalProvider(LocalAppIcons provides i) {
                IconPickerSheet(InstalledApp("Termux", "com.termux", false), null, listOf(IconPackInfo("a.pack", "Arcticons")), onPick = { picked = it }, onDismiss = {})
            }
        }
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Buscar icono en el pack").performTextInput("map")
        compose.waitForIdle()
        compose.onNodeWithContentDescription("terminal").assertDoesNotExist()
        compose.onNodeWithContentDescription("maps alt").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.OnClick)
        assertEquals(dev.vivac.launcher.core.IconOverride.Pack("a.pack", "maps_alt"), picked)
    }

    @Test
    fun `an app wearing the app's own icon shows it even with glyphs everywhere else`() {
        val i = icons()
        compose.setContent {
            androidx.compose.runtime.CompositionLocalProvider(
                LocalAppIcons provides i,
                LocalIconOverrides provides mapOf("org.signal" to dev.vivac.launcher.core.IconOverride.App),
            ) { AppFace(InstalledApp("Signal", "org.signal", false), androidx.compose.ui.graphics.Color.Green) }
        }
        compose.waitForIdle()
        compose.onNodeWithTag("icon:image", useUnmergedTree = true).assertExists()
    }

    @Test
    fun `a themed icon is drawn as a tinted mask`() {
        show(IconStyle.THEMED, AdaptiveIconDrawable(ColorDrawable(Color.WHITE), ColorDrawable(Color.BLACK), ColorDrawable(Color.BLACK)))
        compose.onNodeWithTag("icon:themed", useUnmergedTree = true).assertExists()
    }

    private val app = ApplicationProvider.getApplicationContext<android.app.Application>()
    private val asked = mutableListOf<String>()

    private fun icons(
        appIcon: android.graphics.drawable.Drawable? = ColorDrawable(Color.RED),
        filter: Map<String, String> = mapOf("org.signal/org.signal.Main" to "signal"),
    ) = AppIcons(
        app,
        appIcon = { appIcon },
        component = { pkg -> if (pkg == "org.signal") "org.signal/org.signal.Main" else null },
        filterOf = { pack -> asked += "filter:$pack"; filter },
        packDrawable = { pack, name -> asked += "draw:$pack/$name"; ColorDrawable(Color.BLUE) },
        io = kotlinx.coroutines.Dispatchers.Unconfined,
    )

    @Test
    fun `glyphs need no icon, the apps' own come from android and are kept`() = runBlocking {
        val i = icons()
        assertNull(i.load("org.signal", IconChoice(IconStyle.GLYPHS)))
        val first = i.load("org.signal", IconChoice(IconStyle.ORIGINAL))
        assertNotNull(first)
        assertSame(first, i.load("org.signal", IconChoice(IconStyle.ORIGINAL)))
        assertNull(icons(appIcon = null).load("org.signal", IconChoice(IconStyle.ORIGINAL)))
    }

    @Test
    fun `a pack's icon is found through its appfilter, read once per pack`() = runBlocking {
        val i = icons()
        assertNotNull(i.load("org.signal", IconChoice(IconStyle.PACK, "a.pack")))
        assertNull(i.load("app.organicmaps", IconChoice(IconStyle.PACK, "a.pack")))
        assertNull(i.load("org.signal", IconChoice(IconStyle.PACK, null)))
        assertEquals(listOf("filter:a.pack", "draw:a.pack/signal"), asked)
    }

    @Test
    fun `themed icons are the adaptive icon's monochrome layer, if it has one`() = runBlocking {
        assertNull(icons().load("org.signal", IconChoice(IconStyle.THEMED)))
        val noMono = AdaptiveIconDrawable(ColorDrawable(Color.WHITE), ColorDrawable(Color.BLACK))
        assertNull(icons(appIcon = noMono).load("org.signal", IconChoice(IconStyle.THEMED)))
    }

    @Test
    fun `packs are the apps that answer the ADW or Nova theme action, and the real loaders fail softly`() {
        val pm = shadowOf(app.packageManager)
        fun pack(pkg: String, label: String) = ResolveInfo().apply {
            activityInfo = ActivityInfo().apply { packageName = pkg; name = "$pkg.Main"; nonLocalizedLabel = label; applicationInfo = android.content.pm.ApplicationInfo().apply { packageName = pkg } }
            nonLocalizedLabel = label
        }
        pm.addResolveInfoForIntent(Intent("org.adw.ActivityStarter.THEMES"), pack("z.pack", "Zeta"))
        pm.addResolveInfoForIntent(Intent("com.novalauncher.THEME"), pack("a.pack", "Arcticons"))
        pm.addResolveInfoForIntent(Intent("com.novalauncher.THEME"), pack("z.pack", "Zeta"))
        assertEquals(listOf(IconPackInfo("a.pack", "Arcticons"), IconPackInfo("z.pack", "Zeta")), AppIcons.packs(app))
        assertEquals(emptyMap<String, String>(), AppIcons.readFilter(app, "not.installed"))
        assertNull(AppIcons.drawableOf(app, "not.installed", "x"))
        val real = AppIcons(app)
        runBlocking { assertNull(real.load("not.installed", IconChoice(IconStyle.PACK, "not.installed"))) }
        runBlocking { real.load(app.packageName, IconChoice(IconStyle.ORIGINAL)) }
        assertEquals(Process.myUserHandle(), Process.myUserHandle())
    }
}
