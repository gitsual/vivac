package dev.vivac.launcher.campamento

import java.net.URLDecoder
import java.net.URLEncoder

/** Something placed on a page of the home screen: page 0 is the Campamento, 1 onwards the laderas to its right. */
sealed interface Item {
    val page: Int
}

/** A widget, by the app-widget id Android gave it; [rows] is the height you chose, 0 for the widget's own. */
data class Placed(val id: Int, override val page: Int = 0, val rows: Int = 0) : Item

/** An app put on a ladera. The Campamento keeps its apps on its own route (see [Home.pinned]). */
data class Shelved(val packageName: String, override val page: Int) : Item

/** An app's shortcut (e.g. a chat) put on a ladera; [label] is what the app called it when it was pinned. */
data class Pinned(val packageName: String, val id: String, val label: String, override val page: Int) : Item

/** An empty cell on a ladera's grid, kept so the things after it stay in the cells you put them in. */
data class Gap(override val page: Int) : Item

/** A folder on a ladera: a name and the apps in it, in order. */
data class Folder(val id: String, val name: String, val apps: List<String>, override val page: Int) : Item

/**
 * What sits on each page, in order. Pages never have gaps: a ladera left empty closes and the ones after
 * it move down; the Campamento never closes.
 */
data class WidgetBoard(val items: List<Item> = emptyList()) {
    val ids: List<Int> get() = items.filterIsInstance<Placed>().map { it.id }
    val apps: List<String> get() = items.filterIsInstance<Shelved>().map { it.packageName }

    /** The Campamento plus every ladera that holds something. */
    val pages: Int get() = (items.maxOfOrNull { it.page } ?: 0) + 1

    fun onPage(page: Int): List<Item> = items.filter { it.page == page }

    fun placed(id: Int): Placed? = items.firstOrNull { it is Placed && it.id == id } as Placed?

    fun add(id: Int) = if (placed(id) != null) this else WidgetBoard(items + Placed(id))

    fun remove(id: Int) = WidgetBoard(items.filterNot { it is Placed && it.id == id }).compact()

    /** Puts an app at the end of a ladera (never the Campamento), moving it there if it was on another. */
    fun addApp(packageName: String, page: Int): WidgetBoard =
        if (Shelved(packageName, page.coerceAtLeast(1)) in items) this else WidgetBoard(items.filterNot { it is Shelved && it.packageName == packageName } + Shelved(packageName, page.coerceAtLeast(1))).compact()

    /** Puts an app at [index] among the things on a ladera (moving it if it was elsewhere); past the end appends. */
    fun insertApp(packageName: String, page: Int, index: Int): WidgetBoard =
        place(Shelved(packageName, page.coerceAtLeast(1)), index) { it is Shelved && it.packageName == packageName }

    /** Takes an app off its ladera, leaving its cell empty so the ones after it stay put. */
    fun vacate(packageName: String): WidgetBoard =
        WidgetBoard(items.map { if (it is Shelved && it.packageName == packageName) Gap(it.page) else it }).compact()

    /** Moves a shortcut or a folder to [index] on a ladera (apps and widgets have their own moves). */
    fun moveItem(item: Item, page: Int, index: Int): WidgetBoard {
        val target = page.coerceAtLeast(1)
        val moved = when (item) {
            is Pinned -> item.copy(page = target)
            is Folder -> item.copy(page = target)
            else -> return this
        }
        return place(moved, index) { it == item }
    }

    /**
     * Puts an app, a shortcut or a folder in cell [index] of a ladera's grid, leaving its old cell empty. An empty
     * cell takes it; past the end, the cells before it stay empty ([Int.MAX_VALUE] is just the end); a taken cell
     * makes room by pushing things along to the nearest empty cell among the same apps, else everything after it.
     */
    private fun place(item: Item, index: Int, same: (Item) -> Boolean): WidgetBoard {
        val rest = items.map { if (same(it)) Gap(it.page) else it }
        val onTarget = rest.filter { it.page == item.page }.toMutableList()
        when {
            index == Int.MAX_VALUE -> onTarget.add(item)
            index >= onTarget.size -> { repeat(index - onTarget.size) { onTarget.add(Gap(item.page)) }; onTarget.add(item) }
            onTarget[index] is Gap -> onTarget[index] = item
            else -> {
                nearestGap(onTarget, index)?.let { onTarget.removeAt(it) }
                onTarget.add(index.coerceAtMost(onTarget.size), item)
            }
        }
        val last = maxOf(item.page, rest.maxOfOrNull { it.page } ?: 0)
        return WidgetBoard((0..last).flatMap { p -> if (p == item.page) onTarget else rest.filter { it.page == p } }).compact()
    }

    /** The empty cell nearest [index] with no widget between them (after it on a tie), or null. */
    private fun nearestGap(cells: List<Item>, index: Int): Int? {
        if (cells[index] is Placed) return null
        val after = (index + 1 until cells.size).takeWhile { cells[it] !is Placed }.firstOrNull { cells[it] is Gap }
        val before = (index - 1 downTo 0).takeWhile { cells[it] !is Placed }.firstOrNull { cells[it] is Gap }
        return when {
            after == null -> before
            before == null -> after
            else -> if (after - index <= index - before) after else before
        }
    }

    /** Puts a widget at [index] among the things on [page], the camp included, keeping its rows. */
    fun insertWidget(id: Int, page: Int, index: Int): WidgetBoard {
        val widget = placed(id) ?: return this
        val target = page.coerceIn(0, pages)
        // The cells as they are on screen, so [index] means the same cell once the widget has left its place.
        val cells = onPage(target)
        val from = cells.indexOf(widget)
        val rest = cells - widget
        val at = if (from in 0 until index) index - 1 else index
        return insert(widget.copy(page = target), rowStart(rest, at)) { it == widget }
    }

    /**
     * Where a widget let go over cell [index] goes: the start of that cell's row, since a widget is a whole row of
     * four cells and never splits the apps sharing a row. Past the end, or over another widget, it stays as given.
     */
    private fun rowStart(cells: List<Item>, index: Int): Int {
        if (index !in cells.indices || cells[index] is Placed) return index
        val blockStart = (index downTo 0).firstOrNull { cells[it] is Placed }?.plus(1) ?: 0
        return blockStart + (index - blockStart) / 4 * 4
    }

    private fun insert(item: Item, index: Int, same: (Item) -> Boolean): WidgetBoard {
        val rest = items.filterNot(same)
        val onTarget = rest.filter { it.page == item.page }.toMutableList()
        onTarget.add(index.coerceIn(0, onTarget.size), item)
        val last = maxOf(item.page, rest.maxOfOrNull { it.page } ?: 0)
        return WidgetBoard((0..last).flatMap { p -> if (p == item.page) onTarget else rest.filter { it.page == p } }).compact()
    }

    /** The ladera things from outside (another app's "add to home screen") go to: the last one, or the first. */
    val lastLadera: Int get() = (pages - 1).coerceAtLeast(1)

    /** A new widget on the last ladera, as when an app asks to add one. */
    fun addOnLadera(id: Int) = if (placed(id) != null) this else WidgetBoard(items + Placed(id, lastLadera))

    /** A shortcut at the end of a ladera (never the camp), once. */
    fun addShortcut(packageName: String, id: String, label: String, page: Int): WidgetBoard =
        if (items.any { it is Pinned && it.packageName == packageName && it.id == id }) this
        else WidgetBoard(items + Pinned(packageName, id, label, page.coerceAtLeast(1))).compact()

    fun removeShortcut(packageName: String, id: String) =
        WidgetBoard(items.filterNot { it is Pinned && it.packageName == packageName && it.id == id }).compact()

    /** The ids of [packageName]'s shortcuts on the home screen, which Android must keep pinned. */
    fun shortcutsOf(packageName: String): List<String> = items.filterIsInstance<Pinned>().filter { it.packageName == packageName }.map { it.id }

    fun folder(id: String): Folder? = items.firstOrNull { it is Folder && it.id == id } as Folder?

    fun folderOf(packageName: String): Folder? = items.firstOrNull { it is Folder && packageName in it.apps } as Folder?

    /** A folder holding [packageName]: in the app's place if it is on a ladera, else at the end of [page]. */
    fun newFolder(name: String, packageName: String, page: Int): WidgetBoard {
        val id = "f" + ((items.filterIsInstance<Folder>().mapNotNull { it.id.drop(1).toIntOrNull() }.maxOrNull() ?: 0) + 1)
        val shelved = items.firstOrNull { it is Shelved && it.packageName == packageName }
        val folder = Folder(id, name, listOf(packageName), shelved?.page ?: page.coerceAtLeast(1))
        val rest = withoutInFolders(packageName)
        return if (shelved != null) WidgetBoard(rest.items.map { if (it == shelved) folder else it }) else WidgetBoard(rest.items + folder).compact()
    }

    /** Puts an app in a folder (once), taking it off any ladera spot or other folder. */
    fun addToFolder(id: String, packageName: String): WidgetBoard {
        val target = folder(id) ?: return this
        if (packageName in target.apps) return this
        val rest = WidgetBoard(withoutInFolders(packageName).items.filterNot { it is Shelved && it.packageName == packageName })
        return WidgetBoard(rest.items.map { if (it is Folder && it.id == id) it.copy(apps = it.apps + packageName) else it }).compact()
    }

    /** Takes an app out of a folder; a folder left with one app becomes that app, an empty one goes. */
    fun removeFromFolder(id: String, packageName: String): WidgetBoard {
        val target = folder(id) ?: return this
        return WidgetBoard(items.mapNotNull { if (it == target) settle(target.copy(apps = target.apps - packageName)) else it }).compact()
    }

    fun renameFolder(id: String, name: String) =
        WidgetBoard(items.map { if (it is Folder && it.id == id) it.copy(name = name) else it })

    private fun withoutInFolders(packageName: String) =
        WidgetBoard(items.mapNotNull { if (it is Folder && packageName in it.apps) settle(it.copy(apps = it.apps - packageName)) else it })

    private fun settle(folder: Folder): Item? = when (folder.apps.size) {
        0 -> null
        1 -> Shelved(folder.apps.single(), folder.page)
        else -> folder
    }

    fun removeApp(packageName: String) = WidgetBoard(items.filterNot { it is Shelved && it.packageName == packageName }).compact()

    /** Forget apps that are no longer installed. */
    fun keepApps(installed: Set<String>) = WidgetBoard(
        items.filter { (it !is Shelved || it.packageName in installed) && (it !is Pinned || it.packageName in installed) }
            .mapNotNull { if (it is Folder) settle(it.copy(apps = it.apps.filter { pkg -> pkg in installed })) else it },
    ).compact()

    /** Sends a widget to the end of [page]; one past the last opens a new ladera. */
    fun moveTo(id: Int, page: Int): WidgetBoard {
        val widget = placed(id) ?: return this
        return WidgetBoard(items - widget + widget.copy(page = page.coerceIn(0, pages))).compact()
    }

    /** Moves a widget earlier (-1) or later (+1) among the things on its page, stopping at the ends. */
    fun shift(id: Int, delta: Int): WidgetBoard {
        val widget = placed(id) ?: return this
        val page = onPage(widget.page)
        val at = page.indexOf(widget)
        val to = (at + delta).coerceIn(0, page.lastIndex)
        if (to == at) return this
        val reordered = page.toMutableList().apply { removeAt(at); add(to, widget) }
        // Rebuild in page order, the reordered page in place of the old one.
        return WidgetBoard((0 until pages).flatMap { p -> if (p == widget.page) reordered else onPage(p) })
    }

    fun resize(id: Int, rows: Int): WidgetBoard {
        val widget = placed(id) ?: return this
        return WidgetBoard(items.map { if (it == widget) widget.copy(rows = rows.coerceIn(1, WidgetSize.MAX_ROWS)) else it })
    }

    fun encode(): String = items.joinToString(",") {
        when (it) {
            is Placed -> "${it.id}:${it.page}:${it.rows}"
            is Shelved -> "@${it.packageName}:${it.page}"
            is Gap -> "_:${it.page}"
            is Pinned -> "#" + listOf(it.packageName, it.id, it.label).joinToString("|") { f -> URLEncoder.encode(f, "UTF-8") } + ":${it.page}"
            is Folder -> "%" + listOf(it.id, it.name, it.apps.joinToString(";")).joinToString("|") { f -> URLEncoder.encode(f, "UTF-8") } + ":${it.page}"
        }
    }

    /** This board with every ladera tidied, as after any change to it. */
    fun tidied(): WidgetBoard = compact()

    /** One page's things tidied as [compact] says: cells in blocks of four between widgets. */
    private fun tidy(page: List<Item>): List<Item> {
        val out = mutableListOf<Item>()
        val block = mutableListOf<Item>()
        fun close(beforeWidget: Boolean) {
            if (block.any { it !is Gap }) {
                out += block
                if (beforeWidget) repeat((4 - block.size % 4) % 4) { out += Gap(block.first().page) }
            }
            block.clear()
        }
        page.forEach { item -> if (item is Placed) { close(beforeWidget = true); out += item } else block += item }
        close(beforeWidget = false)
        // The empty cells that end the page go.
        return out.dropLastWhile { it is Gap }
    }

    /**
     * Tidies each ladera's grid: a row of apps cut short by a widget goes on in empty cells up to it (so things can
     * land there), a row with nothing in it is dropped, and so are the empty cells that end a ladera. Then renumbers
     * pages so there are no empty laderas between the ones in use.
     */
    private fun compact(): WidgetBoard {
        val trimmed = (0..(items.maxOfOrNull { it.page } ?: 0)).flatMap { p -> tidy(items.filter { it.page == p }) }
        val used = trimmed.map { it.page }.filter { it > 0 }.distinct().sorted()
        val renumber = used.withIndex().associate { (i, p) -> p to i + 1 }
        return WidgetBoard(trimmed.map { item ->
            val page = renumber[item.page] ?: 0
            when (item) {
                is Placed -> item.copy(page = page)
                is Shelved -> item.copy(page = page)
                is Pinned -> item.copy(page = page)
                is Folder -> item.copy(page = page)
                is Gap -> item.copy(page = page)
            }
        })
    }

    companion object {
        /** Reads `id:page:rows` for widgets, `@package:page` for apps and `#package|id|label:page` (URL-encoded) for shortcuts; a bare `id` is the old camp-only format. */
        fun decode(raw: String?) = WidgetBoard(
            raw.orEmpty().split(",").mapNotNull { part ->
                val fields = part.trim().split(":")
                if (fields[0].startsWith("%")) {
                    val parts = fields[0].drop(1).split("|").map { URLDecoder.decode(it, "UTF-8") }
                    if (parts.size != 3 || parts[0].isBlank()) return@mapNotNull null
                    Folder(parts[0], parts[1], parts[2].split(";").filter { it.isNotBlank() }, fields.getOrNull(1)?.toIntOrNull()?.coerceAtLeast(1) ?: 1)
                } else if (fields[0].startsWith("#")) {
                    val parts = fields[0].drop(1).split("|").map { URLDecoder.decode(it, "UTF-8") }
                    if (parts.size != 3 || parts[0].isBlank()) return@mapNotNull null
                    Pinned(parts[0], parts[1], parts[2], fields.getOrNull(1)?.toIntOrNull()?.coerceAtLeast(1) ?: 1)
                } else if (fields[0] == "_") {
                    Gap(fields.getOrNull(1)?.toIntOrNull()?.coerceAtLeast(1) ?: 1)
                } else if (fields[0].startsWith("@")) {
                    val pkg = fields[0].drop(1).takeIf { it.isNotBlank() } ?: return@mapNotNull null
                    Shelved(pkg, fields.getOrNull(1)?.toIntOrNull()?.coerceAtLeast(1) ?: 1)
                } else {
                    val id = fields[0].toIntOrNull() ?: return@mapNotNull null
                    Placed(id, fields.getOrNull(1)?.toIntOrNull() ?: 0, fields.getOrNull(2)?.toIntOrNull() ?: 0)
                }
            }.withIndex().distinctBy { (i, it) ->
                when (it) {
                    is Gap -> "g$i"
                    is Placed -> "w${it.id}"
                    is Shelved -> "a${it.packageName}"
                    is Pinned -> "s${it.packageName}/${it.id}"
                    is Folder -> "f${it.id}"
                }
            }.map { it.value },
        )
    }
}

/** How tall a widget is drawn, and how its size reads in the picker. */
object WidgetSize {
    /** A row of apps on a ladera: the tile and its name. */
    const val CELL_DP = 76
    /** The space between two rows, as the ladera lays them out. */
    const val GAP_DP = 16
    /** From one row to the next: what a widget grows by per row, and what a drag on its size bar counts as one. */
    const val ROW_DP = CELL_DP + GAP_DP
    const val MIN_DP = CELL_DP
    const val MAX_ROWS = 6
    const val MAX_DP = MAX_ROWS * ROW_DP - GAP_DP

    /** How tall [rows] rows are: the rows of apps they replace, with the gaps between them. */
    fun heightOf(rows: Int): Int = rows * ROW_DP - GAP_DP

    /** The rows you chose, else the widget's own, else its minimum height rounded to whole rows: always whole rows. */
    fun heightDp(minHeightDp: Int, targetRows: Int, chosenRows: Int = 0): Int {
        val rows = when {
            chosenRows > 0 -> chosenRows
            targetRows > 0 -> targetRows
            else -> rowsOf(minHeightDp)
        }
        return heightOf(rows).coerceIn(MIN_DP, MAX_DP)
    }

    /** The whole rows a height fills, at least one, at most [MAX_ROWS]. */
    fun rowsOf(heightDp: Int): Int = Math.round((heightDp + GAP_DP) / ROW_DP.toFloat()).coerceIn(1, MAX_ROWS)

    fun cells(targetColumns: Int, targetRows: Int): String =
        if (targetColumns > 0 && targetRows > 0) "$targetColumns × $targetRows" else ""
}
