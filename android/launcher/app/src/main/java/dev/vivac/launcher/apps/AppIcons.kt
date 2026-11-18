package dev.vivac.launcher.apps

import android.content.Context
import android.content.Intent
import android.content.pm.LauncherApps
import android.content.pm.PackageManager
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Process
import android.util.LruCache
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.graphics.drawable.toBitmap
import dev.vivac.launcher.core.IconPackInfo
import dev.vivac.launcher.core.IconStyle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** The icon style in force, and the pack when the style is [IconStyle.PACK]. */
data class IconChoice(val style: IconStyle = IconStyle.GLYPHS, val pack: String? = null)

val LocalIconChoice = compositionLocalOf { IconChoice() }
val LocalAppIcons = compositionLocalOf<AppIcons?> { null }

/**
 * Adapter: an app's icon in the style you chose, loaded off the main thread and kept in memory.
 * Null means "draw vivac's glyph": no themed layer, no icon in the pack, or the app is gone.
 */
class AppIcons(
    context: Context,
    /** The app's launcher icon, and its launcher activity as "package/class". */
    private val appIcon: (String) -> Drawable?,
    private val component: (String) -> String?,
    /** A pack's appfilter, and one of its drawables by name. */
    private val filterOf: (String) -> Map<String, String>,
    private val packDrawable: (pack: String, name: String) -> Drawable?,
    /** Where icons are decoded: off the main thread. */
    private val io: kotlinx.coroutines.CoroutineDispatcher = Dispatchers.IO,
) {
    constructor(context: Context) : this(
        context,
        appIcon = { pkg -> activity(context, pkg)?.getIcon(0) },
        component = { pkg -> activity(context, pkg)?.componentName?.flattenToString() },
        filterOf = { pack -> readFilter(context, pack) },
        packDrawable = { pack, name -> drawableOf(context, pack, name) },
    )

    private val px = (48 * context.resources.displayMetrics.density).toInt()
    private val cache = LruCache<String, ImageBitmap>(300)
    private val filters = mutableMapOf<String, Map<String, String>>()

    suspend fun load(packageName: String, choice: IconChoice): ImageBitmap? {
        if (choice.style == IconStyle.GLYPHS) return null
        val key = "${choice.style}|${choice.pack}|$packageName"
        cache.get(key)?.let { return it }
        return withContext(io) { render(packageName, choice) }?.also { cache.put(key, it) }
    }

    private fun render(packageName: String, choice: IconChoice): ImageBitmap? = when (choice.style) {
        IconStyle.GLYPHS -> null
        IconStyle.ORIGINAL -> appIcon(packageName)?.toBitmap(px, px)?.asImageBitmap()
        IconStyle.THEMED -> themed(appIcon(packageName))
        IconStyle.PACK -> {
            val pack = choice.pack
            val name = pack?.let { p -> component(packageName)?.let { filters.getOrPut(p) { filterOf(p) }[it] } }
            name?.let { packDrawable(pack, it) }?.toBitmap(px, px)?.asImageBitmap()
        }
    }

    /** The app's monochrome layer (Android 13+), drawn as a mask the tile tints with its tone. */
    private fun themed(icon: Drawable?): ImageBitmap? {
        val adaptive = icon as? AdaptiveIconDrawable ?: return null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null
        return adaptive.monochrome?.toBitmap(px, px)?.asImageBitmap()
    }

    companion object {
        private fun activity(context: Context, pkg: String) =
            context.getSystemService(LauncherApps::class.java).getActivityList(pkg, Process.myUserHandle()).firstOrNull()

        /** Packs declare themselves with ADW's theme action (Nova's too); every launcher reads the same appfilter. */
        fun packs(context: Context): List<IconPackInfo> {
            val pm = context.packageManager
            return listOf("org.adw.ActivityStarter.THEMES", "com.novalauncher.THEME")
                .flatMap { pm.queryIntentActivities(Intent(it), PackageManager.MATCH_ALL) }
                .map { IconPackInfo(it.activityInfo.packageName, it.loadLabel(pm).toString()) }
                .distinctBy { it.packageName }
                .sortedBy { it.label.lowercase() }
        }

        fun drawableOf(context: Context, pack: String, name: String): Drawable? = runCatching {
            val res = context.packageManager.getResourcesForApplication(pack)
            val id = res.getIdentifier(name, "drawable", pack).takeIf { it != 0 } ?: res.getIdentifier(name, "mipmap", pack)
            if (id == 0) null else res.getDrawable(id, null)
        }.getOrNull()

        /** res/xml/appfilter, else res/raw/appfilter, else assets/appfilter.xml. */
        fun readFilter(context: Context, pack: String): Map<String, String> = runCatching {
            val res = context.packageManager.getResourcesForApplication(pack)
            val xml = res.getIdentifier("appfilter", "xml", pack)
            if (xml != 0) return@runCatching AppFilter.read(res.getXml(xml))
            val raw = res.getIdentifier("appfilter", "raw", pack)
            if (raw != 0) return@runCatching res.openRawResource(raw).use(AppFilter::parse)
            res.assets.open("appfilter.xml").use(AppFilter::parse)
        }.getOrDefault(emptyMap())
    }
}
