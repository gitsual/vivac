package dev.vivac.launcher.campamento

import org.junit.Assert.assertEquals
import org.junit.Test

class WidgetBoardTest {
    private fun board(vararg placed: Placed) = WidgetBoard(placed.toList())

    @Test
    fun `widgets are added to the camp in order and removed by id`() {
        val b = WidgetBoard().add(7).add(12).add(3)
        assertEquals(listOf(7, 12, 3), b.ids)
        assertEquals(listOf(7, 3), b.remove(12).ids)
        assertEquals(listOf(Placed(7), Placed(12), Placed(3)), b.onPage(0))
    }

    @Test
    fun `adding the same id twice keeps one`() {
        assertEquals(listOf(5), WidgetBoard().add(5).add(5).ids)
    }

    @Test
    fun `the camp is always there, and every ladera with a widget after it`() {
        assertEquals(1, WidgetBoard().pages)
        assertEquals(3, board(Placed(1), Placed(2, page = 2), Placed(3, page = 1)).pages)
    }

    @Test
    fun `moving a widget sends it to the end of that page, and a new page opens past the last`() {
        val b = board(Placed(1), Placed(2), Placed(3, page = 1))
        assertEquals(listOf(Placed(3, page = 1), Placed(1, page = 1)), b.moveTo(1, page = 1).onPage(1))
        val opened = b.moveTo(2, page = b.pages)
        assertEquals(3, opened.pages)
        assertEquals(listOf(Placed(2, page = 2)), opened.onPage(2))
    }

    @Test
    fun `an emptied ladera closes and the ones after it move down, the camp never closes`() {
        val b = board(Placed(1), Placed(2, page = 1), Placed(3, page = 2))
        val closed = b.moveTo(2, page = 0)
        assertEquals(2, closed.pages)
        assertEquals(listOf(Placed(3, page = 1)), closed.onPage(1))
        assertEquals(1, board(Placed(1, page = 1)).moveTo(1, page = 0).pages)
        assertEquals(1, board(Placed(1)).remove(1).pages)
    }

    @Test
    fun `a widget moves earlier or later within its page, stopping at the ends`() {
        val b = board(Placed(1), Placed(9, page = 1), Placed(2), Placed(3))
        assertEquals(listOf(1, 3, 2), b.shift(3, -1).onPage(0).map { (it as Placed).id })
        assertEquals(listOf(2, 1, 3), b.shift(1, +1).onPage(0).map { (it as Placed).id })
        assertEquals(listOf(1, 2, 3), b.shift(1, -1).onPage(0).map { (it as Placed).id })
        assertEquals(listOf(1, 2, 3), b.shift(3, +1).onPage(0).map { (it as Placed).id })
    }

    @Test
    fun `apps go on a ladera, once each, after what is already there`() {
        val b = board(Placed(1, page = 1)).addApp("com.whatsapp", page = 1).addApp("org.telegram", page = 1).addApp("com.whatsapp", page = 1)
        assertEquals(listOf(Placed(1, page = 1), Shelved("com.whatsapp", 1), Shelved("org.telegram", 1)), b.onPage(1))
        assertEquals(listOf("com.whatsapp", "org.telegram"), b.apps)
    }

    @Test
    fun `an app put on a new ladera opens it, and taking it off closes it again`() {
        val b = WidgetBoard().addApp("com.whatsapp", page = 1)
        assertEquals(2, b.pages)
        assertEquals(1, b.removeApp("com.whatsapp").pages)
    }

    @Test
    fun `apps are never shelved on the camp, which has its own route`() {
        assertEquals(listOf(Shelved("com.whatsapp", 1)), WidgetBoard().addApp("com.whatsapp", page = 0).onPage(1))
    }

    @Test
    fun `uninstalled apps leave their ladera`() {
        val b = WidgetBoard().addApp("a", 1).addApp("b", 2)
        assertEquals(listOf(Shelved("a", 1)), b.keepApps(setOf("a")).items)
    }

    @Test
    fun `a widget keeps the rows you chose, from one to five`() {
        val b = board(Placed(1))
        assertEquals(3, b.resize(1, rows = 3).placed(1)?.rows)
        assertEquals(WidgetSize.MAX_ROWS, b.resize(1, rows = 9).placed(1)?.rows)
        assertEquals(1, b.resize(1, rows = 0).placed(1)?.rows)
    }

    @Test
    fun `it survives a round trip through storage, and reads the old id-only format`() {
        val b = board(Placed(4), Placed(9, page = 1, rows = 3)).addApp("com.whatsapp", page = 1)
        assertEquals(b, WidgetBoard.decode(b.encode()))
        assertEquals(board(Placed(4), Placed(9)), WidgetBoard.decode("4,9"))
        assertEquals(board(Placed(4)), WidgetBoard.decode("4,x,,"))
        assertEquals(WidgetBoard(), WidgetBoard.decode(null))
    }

    @Test
    fun `a widget is as tall as the rows of apps it takes, the gaps between them included`() {
        // An app row is 76dp, with 16dp between rows: n rows of widget end where n rows of apps end.
        assertEquals(76, WidgetSize.heightOf(1))
        assertEquals(168, WidgetSize.heightOf(2))
        assertEquals(536, WidgetSize.heightOf(6))
        assertEquals(260, WidgetSize.heightDp(minHeightDp = 40, targetRows = 2, chosenRows = 3))
        assertEquals(168, WidgetSize.heightDp(minHeightDp = 40, targetRows = 2))
        // A widget that only gives a minimum height is snapped to whole rows.
        assertEquals(76, WidgetSize.heightDp(minHeightDp = 110, targetRows = 0))
        assertEquals(168, WidgetSize.heightDp(minHeightDp = 150, targetRows = 0))
        assertEquals(WidgetSize.MIN_DP, WidgetSize.heightDp(minHeightDp = 10, targetRows = 0))
        assertEquals(WidgetSize.MAX_DP, WidgetSize.heightDp(minHeightDp = 900, targetRows = 0))
    }

    @Test
    fun `a widget's rows, when you have not chosen, come from its height`() {
        assertEquals(2, WidgetSize.rowsOf(heightDp = 168))
        assertEquals(1, WidgetSize.rowsOf(heightDp = 72))
        assertEquals(6, WidgetSize.MAX_ROWS)
        assertEquals(WidgetSize.MAX_ROWS, WidgetSize.rowsOf(heightDp = 600))
    }

    @Test
    fun `cells read like the system picker`() {
        assertEquals("4 × 2", WidgetSize.cells(targetColumns = 4, targetRows = 2))
        assertEquals("", WidgetSize.cells(targetColumns = 0, targetRows = 0))
    }

    @Test
    fun `an app can be put at a given place among the things on a ladera`() {
        val b = board(Placed(1, page = 1)).addApp("a", 1).addApp("b", 1)
        assertEquals(listOf(Shelved("b", 1), Gap(1), Gap(1), Gap(1), Placed(1, page = 1), Shelved("a", 1)), b.insertApp("b", page = 1, index = 0).onPage(1))
        assertEquals(listOf(Placed(1, page = 1), Shelved("b", 1), Shelved("a", 1)), b.insertApp("b", page = 1, index = 1).onPage(1))
        assertEquals(listOf(Placed(1, page = 1), Shelved("a", 1), Shelved("b", 1), Shelved("c", 1)), b.insertApp("c", page = 1, index = Int.MAX_VALUE).onPage(1))
    }

    private fun gaps(n: Int, page: Int = 1) = List(n) { Gap(page) }

    @Test
    fun `an app let go over an empty cell past the others lands in that cell, empty cells before it`() {
        val b = WidgetBoard().addApp("a", 1)
        assertEquals(listOf(Shelved("a", 1)) + gaps(4) + Shelved("b", 1), b.insertApp("b", page = 1, index = 5).onPage(1))
    }

    @Test
    fun `an app let go over an empty cell between others fills it, and nothing else moves`() {
        val b = WidgetBoard(listOf(Shelved("a", 1)) + gaps(2) + Shelved("b", 1))
        assertEquals(listOf(Shelved("a", 1), Shelved("c", 1), Gap(1), Shelved("b", 1)), b.insertApp("c", page = 1, index = 1).onPage(1))
    }

    @Test
    fun `an app let go over a taken cell pushes the ones after it into the nearest empty cell`() {
        val b = WidgetBoard(listOf(Shelved("a", 1), Shelved("b", 1), Gap(1), Shelved("c", 1)))
        assertEquals(listOf(Shelved("d", 1), Shelved("a", 1), Shelved("b", 1), Shelved("c", 1)), b.insertApp("d", page = 1, index = 0).onPage(1))
    }

    @Test
    fun `an app moved away leaves its cell empty, and empty cells at the end of a ladera are dropped`() {
        val b = WidgetBoard().addApp("a", 1).addApp("b", 1).addApp("c", 1)
        assertEquals(listOf(Gap(1), Shelved("b", 1), Shelved("c", 1), Shelved("a", 1)), b.insertApp("a", page = 1, index = 3).onPage(1))
        val spread = WidgetBoard(listOf(Shelved("a", 1), Gap(1), Shelved("b", 1)))
        assertEquals(listOf(Shelved("a", 1)), spread.insertApp("b", page = 2, index = 0).onPage(1))
        assertEquals(listOf(Shelved("a", 1)), spread.vacate("b").onPage(1))
        assertEquals(listOf(Gap(1), Gap(1), Shelved("b", 1)), spread.vacate("a").onPage(1))
        // A ladera with only empty cells left closes.
        assertEquals(1, WidgetBoard(listOf(Gap(1), Shelved("b", 1))).vacate("b").pages)
    }

    @Test
    fun `empty cells are kept when the board is saved and read back`() {
        val b = WidgetBoard(listOf(Shelved("a", 1), Gap(1), Gap(1), Shelved("b", 1)))
        assertEquals(b, WidgetBoard.decode(b.encode()))
    }

    @Test
    fun `a widget can be put at a given place on any page, the camp included`() {
        val b = board(Placed(1), Placed(2), Placed(3, page = 1)).addApp("a", 1)
        assertEquals(listOf(Placed(2), Placed(1)), b.insertWidget(2, page = 0, index = 0).onPage(0))
        assertEquals(listOf(Placed(3, page = 1), Placed(1, page = 1), Shelved("a", 1)), b.insertWidget(1, page = 1, index = 1).onPage(1))
        assertEquals(listOf(Placed(1), Placed(2), Placed(3)), b.insertWidget(3, page = 0, index = 99).onPage(0))
        assertEquals(b, b.insertWidget(42, page = 0, index = 0))
    }

    @Test
    fun `a widget keeps its chosen rows when it moves`() {
        assertEquals(Placed(1, page = 1, rows = 3), board(Placed(1, rows = 3), Placed(2, page = 1)).insertWidget(1, 1, 0).placed(1))
    }

    @Test
    fun `shortcuts go on a ladera once each, leave with their app, and survive storage with any label`() {
        val b = WidgetBoard().addShortcut("org.signal", "chat-ana", "Ana: hola, ¿qué tal? 50%", page = 1)
            .addShortcut("org.signal", "chat-ana", "Ana: hola, ¿qué tal? 50%", page = 1)
            .addShortcut("app.maps", "home", "Casa", page = 0)
        assertEquals(listOf(Pinned("org.signal", "chat-ana", "Ana: hola, ¿qué tal? 50%", 1), Pinned("app.maps", "home", "Casa", 1)), b.onPage(1))
        assertEquals(b, WidgetBoard.decode(b.encode()))
        assertEquals(listOf(Pinned("app.maps", "home", "Casa", 1)), b.keepApps(setOf("app.maps")).items)
        assertEquals(listOf("home"), b.shortcutsOf("app.maps"))
        assertEquals(1, b.removeShortcut("org.signal", "chat-ana").removeShortcut("app.maps", "home").pages)
    }

    @Test
    fun `things added from outside go on the last ladera, or open the first`() {
        assertEquals(1, WidgetBoard().lastLadera)
        assertEquals(2, board(Placed(1), Placed(2, page = 2), Placed(3, page = 1)).lastLadera)
        assertEquals(listOf(Placed(5, page = 1)), WidgetBoard().addOnLadera(5).onPage(1))
        assertEquals(listOf(Placed(5, page = 1)), WidgetBoard().addOnLadera(5).addOnLadera(5).onPage(1))
    }

    @Test
    fun `a new folder takes the app's place on its ladera, or goes on the given one`() {
        val b = WidgetBoard().addApp("a", 1).addApp("b", 1)
        val f = b.newFolder("Viaje", "a", page = 1)
        assertEquals(listOf(Folder("f1", "Viaje", listOf("a"), 1), Shelved("b", 1)), f.onPage(1))
        assertEquals(listOf(Shelved("a", 1), Shelved("b", 1), Folder("f1", "Nueva", listOf("c"), 1)), b.newFolder("Nueva", "c", page = 1).onPage(1))
        assertEquals("f2", f.newFolder("Otra", "z", 1).items.filterIsInstance<Folder>().last().id)
    }

    @Test
    fun `apps join a folder once, leaving any ladera spot, and a folder left with one app gives it back`() {
        val b = WidgetBoard().addApp("a", 1).addApp("b", 1).newFolder("Viaje", "a", 1)
        val joined = b.addToFolder("f1", "b").addToFolder("f1", "b")
        assertEquals(listOf(Folder("f1", "Viaje", listOf("a", "b"), 1)), joined.onPage(1))
        assertEquals("f1", joined.folderOf("b")?.id)
        val left = joined.removeFromFolder("f1", "b")
        assertEquals(listOf(Shelved("a", 1)), left.onPage(1))
        assertEquals(b, b.addToFolder("nope", "b"))
        assertEquals(b, b.removeFromFolder("nope", "b"))
    }

    @Test
    fun `folders are renamed, forget uninstalled apps, and survive storage with any name`() {
        val b = WidgetBoard().newFolder("Viaje", "a", 1).addToFolder("f1", "b").addToFolder("f1", "c").renameFolder("f1", "Días: 1, 2 | 3")
        assertEquals("Días: 1, 2 | 3", b.folder("f1")?.name)
        assertEquals(b, WidgetBoard.decode(b.encode()))
        assertEquals(listOf("a", "c"), b.keepApps(setOf("a", "c")).folder("f1")?.apps)
        assertEquals(listOf(Shelved("a", 1)), b.keepApps(setOf("a")).onPage(1))
        assertEquals(1, b.keepApps(emptySet()).pages)
        assertEquals(b, b.renameFolder("nope", "x"))
    }

    @Test
    fun `a shortcut or a folder moves to a place on any ladera, never the camp`() {
        val b = WidgetBoard().addApp("a", 1).addShortcut("s", "x", "X", 1).newFolder("F", "z", 2)
        val pin = b.items.filterIsInstance<Pinned>().single()
        assertEquals(listOf(Pinned("s", "x", "X", 1), Shelved("a", 1)), b.moveItem(pin, page = 1, index = 0).onPage(1))
        val folder = b.folder("f1")!!
        assertEquals(listOf(Folder("f1", "F", listOf("z"), 1), Shelved("a", 1), Pinned("s", "x", "X", 1)), b.moveItem(folder, page = 1, index = 0).onPage(1))
        assertEquals(1, b.moveItem(folder, page = 0, index = 0).folder("f1")?.page)
        assertEquals(b, b.moveItem(Shelved("a", 1), page = 2, index = 0).let { b })
    }

    @Test
    fun `a row of apps cut short by a widget keeps its free cells, so an app can land beside the others`() {
        val b = WidgetBoard(listOf(Shelved("a", 1), Placed(1, page = 1), Shelved("z", 1)))
        // The row of "a" goes on in three empty cells up to the widget.
        assertEquals(listOf(Shelved("a", 1), Gap(1), Gap(1), Gap(1), Placed(1, page = 1), Shelved("z", 1)), b.addApp("q", 2).removeApp("q").onPage(1))
        val placed = b.addApp("q", 2).removeApp("q").insertApp("t", page = 1, index = 2)
        assertEquals(listOf(Shelved("a", 1), Gap(1), Shelved("t", 1), Gap(1), Placed(1, page = 1), Shelved("z", 1)), placed.onPage(1))
    }

    @Test
    fun `a row with nothing in it before a widget is not kept`() {
        val b = WidgetBoard(listOf(Shelved("a", 1), Placed(1, page = 1)))
        assertEquals(listOf(Placed(1, page = 1)), b.vacate("a").onPage(1))
    }

    @Test
    fun `a widget let go in the middle of a row takes the whole row, never splitting the apps in it`() {
        val apps = listOf("a", "b", "c", "d", "e", "f").map { Shelved(it, 1) }
        val b = WidgetBoard(apps + Placed(1, page = 1))
        // Over "b" (second cell of the first row): the widget goes above that row.
        assertEquals(listOf(Placed(1, page = 1)) + apps, b.insertWidget(1, page = 1, index = 1).onPage(1))
        // Over "f" (second cell of the second row): above the second row, the first row untouched.
        assertEquals(apps.take(4) + Placed(1, page = 1) + apps.drop(4), b.insertWidget(1, page = 1, index = 5).onPage(1))
    }
}
