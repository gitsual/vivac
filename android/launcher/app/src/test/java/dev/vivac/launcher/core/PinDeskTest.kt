package dev.vivac.launcher.core

import dev.vivac.launcher.campamento.Pinned
import dev.vivac.launcher.campamento.Placed
import dev.vivac.launcher.campamento.WidgetBoard
import dev.vivac.launcher.widgets.WidgetOption
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PinDeskTest {
    private val store = FakeStore()
    private val widgets = FakeWidgets()
    private val accepted = mutableListOf<Int>()
    private var agrees = true
    private fun desk() = PinDesk(store, widgets, accept = { id -> accepted += id; agrees })
    private val clock = WidgetOption("a.clock/.Big", "Reloj grande", "Reloj", "a.clock", "4 × 2")
    private fun board() = WidgetBoard.decode(store.values[Launcher.KEY_WIDGETS])

    @Test
    fun `a shortcut an app offers goes on the last ladera once android accepts it`() {
        store.values[Launcher.KEY_WIDGETS] = WidgetBoard().addApp("x", 1).addApp("y", 2).encode()
        val d = desk()
        assertEquals(2, d.ladera)
        d.add(PinOffer.Shortcut("org.signal", "chat-ana", "Ana"))
        assertTrue(d.done)
        assertEquals(listOf(-1), accepted)
        assertTrue(Pinned("org.signal", "chat-ana", "Ana", 2) in board().onPage(2))
    }

    @Test
    fun `nothing is placed when android withdraws the request, or when you say no`() {
        agrees = false
        desk().add(PinOffer.Shortcut("org.signal", "chat-ana", "Ana"))
        assertEquals(WidgetBoard(), board())
        val d = desk()
        d.decline()
        assertTrue(d.done)
        assertEquals(emptyList<Int>(), accepted.drop(1))
    }

    @Test
    fun `a widget an app offers is bound, accepted with its id, and placed on a ladera`() {
        val d = desk()
        assertEquals("Reloj grande", PinOffer.Widget(clock).label)
        d.add(PinOffer.Widget(clock))
        assertEquals(listOf(1), accepted)
        assertEquals(listOf(Placed(1, page = 1)), board().onPage(1))
        assertTrue(d.done)
    }

    @Test
    fun `a widget waits for the bind dialog and its setup screen, and is dropped if either is refused`() {
        widgets.allowed = false
        widgets.configurable = setOf(clock.key)
        val d = desk()
        d.add(PinOffer.Widget(clock))
        assertEquals(listOf("askBind:1"), widgets.calls)
        assertFalse(d.done)
        widgets.accept(1)
        d.onWidgetResult(WidgetStep.BIND, ok = true)
        assertEquals(listOf("askBind:1", "configure:1"), widgets.calls)
        d.onWidgetResult(WidgetStep.CONFIGURE, ok = true)
        assertEquals(listOf(Placed(1, page = 1)), board().onPage(1))
        assertTrue(d.done)

        val refused = desk()
        refused.add(PinOffer.Widget(clock))
        refused.onWidgetResult(WidgetStep.BIND, ok = false)
        assertTrue("delete:2" in widgets.calls)
        assertTrue(refused.done)
        refused.onWidgetResult(WidgetStep.BIND, ok = true)
    }

    @Test
    fun `a widget whose request is gone by the time it is bound is let go`() {
        agrees = false
        val d = desk()
        d.add(PinOffer.Widget(clock))
        assertTrue("delete:1" in widgets.calls)
        assertEquals(WidgetBoard(), board())
        assertTrue(d.done)
    }

    @Test
    fun `a desk rebuilt after process death carries on with its widget`() {
        widgets.allowed = false
        val d = desk()
        d.add(PinOffer.Widget(clock))
        widgets.accept(1)
        val again = PinDesk(store, widgets, accept = { true }, pendingWidget = d.pendingWidget)
        again.onWidgetResult(WidgetStep.BIND, ok = true)
        assertEquals(listOf(1), board().ids)
    }
}
