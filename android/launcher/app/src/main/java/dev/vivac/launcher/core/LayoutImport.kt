package dev.vivac.launcher.core

import dev.vivac.launcher.campamento.Folder
import dev.vivac.launcher.campamento.Home
import dev.vivac.launcher.campamento.Item
import dev.vivac.launcher.campamento.Shelved

/** One row of a Launcher3 `favorites` table, the home layout Nova and Lawnchair keep in their backups. */
data class Launcher3Row(
    val id: Long,
    /** -100 the desktop, -101 the hotseat (dock), or the id of the folder it is in. */
    val container: Long,
    val screen: Int,
    val cellX: Int,
    val cellY: Int,
    /** Order inside a folder. */
    val rank: Int,
    /** 0 app, 1 shortcut, 2 folder, 4 widget, 6 deep shortcut. */
    val itemType: Int,
    val intent: String?,
    val title: String?,
)

/** A layout brought from another launcher: the dock, the camp's route, the laderas' items, and how many apps came. */
data class ImportedCamp(val dock: List<String>, val route: List<String>, val laderas: List<Item>, val count: Int)

/**
 * Turns another launcher's home into vivac's: the hotseat becomes the dock, the first screen the route (what does
 * not fit, and its folders, go to the first ladera), every other screen a ladera of its own. Only installed apps
 * come; widgets and shortcuts stay behind (their ids belong to the other launcher).
 */
object LayoutImport {
    private const val DESKTOP = -100L
    private const val HOTSEAT = -101L
    private const val APP = 0
    private const val FOLDER = 2

    fun packageOf(intent: String?): String? = intent?.let { Regex("component=([^/;]+)/").find(it)?.groupValues?.get(1) }

    fun toCamp(rows: List<Launcher3Row>, installed: Set<String>): ImportedCamp {
        val appOf = { r: Launcher3Row -> packageOf(r.intent)?.takeIf { r.itemType == APP && it in installed } }
        val byPlace = compareBy<Launcher3Row>({ it.screen }, { it.cellY }, { it.cellX })
        val dock = rows.filter { it.container == HOTSEAT }.sortedWith(compareBy({ it.screen }, { it.cellX })).mapNotNull(appOf).distinct().take(Home.DOCK_MAX)
        val desktop = rows.filter { it.container == DESKTOP && (it.itemType == APP || it.itemType == FOLDER) }.sortedWith(byPlace)

        fun item(r: Launcher3Row, page: Int): Item? = when (r.itemType) {
            FOLDER -> {
                val apps = rows.filter { it.container == r.id }.sortedWith(compareBy({ it.rank }, { it.cellY }, { it.cellX })).mapNotNull(appOf).distinct()
                when (apps.size) {
                    0 -> null
                    1 -> Shelved(apps.single(), page)
                    else -> Folder("import-${r.id}", r.title.orEmpty().ifBlank { "Carpeta" }, apps, page)
                }
            }
            else -> appOf(r)?.let { Shelved(it, page) }
        }

        val first = desktop.filter { it.screen == desktop.firstOrNull()?.screen }
        val firstApps = first.filter { it.itemType == APP }.mapNotNull(appOf).filterNot { it in dock }.distinct()
        val route = firstApps.take(Home.PINNED_MAX)
        val spill = firstApps.drop(Home.PINNED_MAX).map { Shelved(it, 1) } + first.filter { it.itemType == FOLDER }.mapNotNull { item(it, 1) }
        val start = if (spill.isEmpty()) 1 else 2
        val others = desktop.filter { it !in first }.groupBy { it.screen }.values.mapIndexedNotNull { i, screen ->
            screen.mapNotNull { item(it, start + i) }.takeIf { it.isNotEmpty() }
        }
        // Pages without anything left close up, as laderas do.
        val laderas = spill + others.mapIndexed { i, items -> items.map { it.onPage(start + i) } }.flatten()
        val count = dock.size + route.size + laderas.sumOf { if (it is Folder) it.apps.size else 1 }
        return ImportedCamp(dock, route, laderas, count)
    }

    private fun Item.onPage(page: Int): Item = when (this) {
        is Shelved -> copy(page = page)
        is Folder -> copy(page = page)
        else -> this
    }
}
