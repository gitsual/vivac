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
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf

@RunWith(AndroidJUnit4::class)
class AppIconsTest {
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
