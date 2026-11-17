package dev.vivac.launcher.apps

import android.content.Context
import android.content.pm.LauncherApps
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Process
import android.util.LruCache
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.graphics.drawable.toBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** An app's icon as vivac draws it. */
sealed interface AppIcon {
    /** The themed-icon layer (one ink); vivac tints it with the tile's tone. */
    data class Glyph(val image: ImageBitmap) : AppIcon

    /** The app's own colour icon, used when it ships no themed layer. */
    data class Full(val image: ImageBitmap) : AppIcon
}

/** Adapter: loads icons off the main thread and keeps them in memory. [find] gives an app's raw icon. */
class AppIcons(context: Context, private val find: (packageName: String) -> Drawable?) {
    /** Icons as LauncherApps gives them for the current profile. */
    constructor(context: Context) : this(context, { pkg ->
        context.getSystemService(LauncherApps::class.java).getActivityList(pkg, Process.myUserHandle()).firstOrNull()?.getIcon(0)
    })

    private val density = context.resources.displayMetrics.density
    private val cache = LruCache<String, AppIcon>(256)

    suspend fun load(packageName: String): AppIcon? {
        cache.get(packageName)?.let { return it }
        return withContext(Dispatchers.IO) {
            val drawable = find(packageName) ?: return@withContext null
            render(drawable)?.also { cache.put(packageName, it) }
        }
    }

    /** Drop cached icons, e.g. after an app update changes its icon. */
    fun forget(packageName: String) {
        cache.remove(packageName)
    }

    private fun render(drawable: Drawable): AppIcon? {
        // A 108-unit adaptive layer drawn at 48dp shows its 72-unit visible area at 32dp, the glyph size of the design.
        val layerPx = (48 * density).toInt()
        val mono = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) (drawable as? AdaptiveIconDrawable)?.monochrome else null
        if (mono != null) {
            val glyph = mono.toBitmap(layerPx, layerPx)
            // Some apps (Google Drive) ship a themed layer that renders fully transparent here.
            if (!glyph.isBlank()) return AppIcon.Glyph(glyph.asImageBitmap())
        }
        val fullPx = (44 * density).toInt()
        return AppIcon.Full(drawable.toBitmap(fullPx, fullPx).asImageBitmap())
    }

    /** True when no sampled pixel is visibly opaque (every 4th pixel per axis is enough for a glyph). */
    private fun Bitmap.isBlank(): Boolean {
        for (y in 0 until height step 4) for (x in 0 until width step 4) {
            if (Color.alpha(getPixel(x, y)) > 24) return false
        }
        return true
    }
}
