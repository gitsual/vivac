package dev.vivac.launcher.core

import dev.vivac.launcher.campamento.Folder
import dev.vivac.launcher.campamento.Shelved
import org.junit.Assert.assertEquals
import org.junit.Test

class LayoutImportTest {
    private fun app(id: Long, pkg: String, container: Long = DESKTOP, screen: Int = 0, x: Int = 0, y: Int = 0, rank: Int = 0) =
        Launcher3Row(id, container, screen, x, y, rank, itemType = 0, intent = "#Intent;action=android.intent.action.MAIN;component=$pkg/.Main;end", title = pkg)

    private val installed = setOf("a.dock1", "a.dock2", "a.home1", "a.home2", "a.page1", "a.f1", "a.f2", "a.lone")

    @Test
    fun `the hotseat becomes the dock, the first screen the route, the others laderas, folders stay folders`() {
        val rows = listOf(
            app(1, "a.dock2", container = HOTSEAT, screen = 1, x = 1),
            app(2, "a.dock1", container = HOTSEAT, screen = 0, x = 0),
            app(3, "a.home2", screen = 0, x = 1, y = 0),
            app(4, "a.home1", screen = 0, x = 0, y = 0),
            app(5, "not.installed", screen = 0, x = 2),
            Launcher3Row(6, DESKTOP, 2, 0, 0, 0, itemType = 2, intent = null, title = "Viaje"),
            app(7, "a.f2", container = 6, rank = 1),
            app(8, "a.f1", container = 6, rank = 0),
            app(9, "a.page1", screen = 2, x = 1),
            Launcher3Row(10, DESKTOP, 3, 0, 0, 0, itemType = 2, intent = null, title = "Una"),
            app(11, "a.lone", container = 10),
            // A widget and a deep shortcut have nothing to carry over.
            Launcher3Row(12, DESKTOP, 0, 0, 1, 0, itemType = 4, intent = null, title = null),
            Launcher3Row(13, DESKTOP, 0, 0, 2, 0, itemType = 6, intent = "#Intent;component=a.home1/.X;end", title = "Atajo"),
        )
        val camp = LayoutImport.toCamp(rows, installed)
        assertEquals(listOf("a.dock1", "a.dock2"), camp.dock)
        assertEquals(listOf("a.home1", "a.home2"), camp.route)
        assertEquals(
            listOf(Folder("import-6", "Viaje", listOf("a.f1", "a.f2"), 1), Shelved("a.page1", 1), Shelved("a.lone", 2)),
            camp.laderas,
        )
        assertEquals(8, camp.count)
    }

    @Test
    fun `a full route spills onto the first ladera, and a folder on the first screen goes there too`() {
        val many = (1..14).map { app(it.toLong(), "p.$it", screen = 0, x = it % 4, y = it / 4) }
        val rows = many + listOf(Launcher3Row(99, DESKTOP, 0, 0, 9, 0, itemType = 2, intent = null, title = "F"), app(100, "p.a", container = 99), app(101, "p.b", container = 99))
        val camp = LayoutImport.toCamp(rows, many.map { "p.${it.id}" }.toSet() + setOf("p.a", "p.b"))
        assertEquals(12, camp.route.size)
        assertEquals(setOf(Shelved("p.13", 1), Shelved("p.14", 1), Folder("import-99", "F", listOf("p.a", "p.b"), 1)), camp.laderas.toSet())
    }

    @Test
    fun `the package comes from the intent's component, else nothing`() {
        assertEquals("org.signal", LayoutImport.packageOf("#Intent;component=org.signal/.Main;end"))
        assertEquals(null, LayoutImport.packageOf("#Intent;action=x;end"))
        assertEquals(null, LayoutImport.packageOf(null))
    }

    private companion object {
        const val DESKTOP = -100L
        const val HOTSEAT = -101L
    }
}
