package dev.vivac.launcher.avisos

import org.junit.Assert.assertEquals
import org.junit.Test

class AvisosTest {
    private fun aviso(key: String, pkg: String, at: Long, title: String = "t$key", ongoing: Boolean = false, summary: Boolean = false) =
        Aviso(key, pkg, title, "texto", at, ongoing = ongoing, clearable = !ongoing, summary = summary, canReply = false)

    @Test
    fun `notices are grouped by app, newest app first and newest notice first within it`() {
        val shelf = Avisos.shelf(listOf(aviso("1", "chat", 10), aviso("2", "mail", 30), aviso("3", "chat", 20)))
        assertEquals(listOf("mail", "chat"), shelf.map { it.packageName })
        assertEquals(listOf("3", "1"), shelf[1].avisos.map { it.key })
    }

    @Test
    fun `group summaries and notices with nothing to read are left out`() {
        val shelf = Avisos.shelf(listOf(aviso("1", "chat", 10, summary = true), aviso("2", "chat", 20, title = "").copy(text = ""), aviso("3", "chat", 5)))
        assertEquals(listOf("3"), shelf.single().avisos.map { it.key })
    }

    @Test
    fun `apps with only ongoing notices (music, a download) go after the rest`() {
        val shelf = Avisos.shelf(listOf(aviso("1", "music", 50, ongoing = true), aviso("2", "chat", 10)))
        assertEquals(listOf("chat", "music"), shelf.map { it.packageName })
    }

    @Test
    fun `how long ago reads like people say it`() {
        val min = 60_000L
        assertEquals("ahora", Avisos.ago(0, 30_000))
        assertEquals("hace 5 min", Avisos.ago(0, 5 * min))
        assertEquals("hace 2 h", Avisos.ago(0, 125 * min))
        assertEquals("ayer", Avisos.ago(0, 30 * 60 * min))
        assertEquals("hace 3 d", Avisos.ago(0, 3 * 24 * 60 * min))
        assertEquals("ahora", Avisos.ago(100, 0))
    }
}
