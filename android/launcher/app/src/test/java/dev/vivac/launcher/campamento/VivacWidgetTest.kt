package dev.vivac.launcher.campamento

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class VivacWidgetTest {
    @Test
    fun `vivac's widgets are named by kind and app, and read back from that`() {
        val chats = VivacWidget.Chats("com.whatsapp")
        val atajos = VivacWidget.Atajos("com.anthropic.claude")
        assertEquals("vivac:chats:com.whatsapp", chats.key)
        assertEquals(chats, VivacWidget.fromKey(chats.key))
        assertEquals(atajos, VivacWidget.fromKey(atajos.key))
        assertNull(VivacWidget.fromKey("com.whatsapp/.Widget"))
        assertNull(VivacWidget.fromKey("vivac:nope:x"))
    }

    @Test
    fun `chats take three rows when placed, shortcuts one`() {
        assertEquals(3, VivacWidget.Chats("a").rows)
        assertEquals(1, VivacWidget.Atajos("a").rows)
    }

    @Test
    fun `the placed ones are kept by their id, unknown entries dropped`() {
        val placed = mapOf(-1 to VivacWidget.Chats("com.whatsapp"), -2 to VivacWidget.Atajos("com.anthropic.claude"))
        assertEquals(placed, VivacWidget.decode(VivacWidget.encode(placed)))
        assertEquals(emptyMap<Int, VivacWidget>(), VivacWidget.decode(null))
        assertEquals(mapOf(-1 to VivacWidget.Chats("a")), VivacWidget.decode("-1=vivac:chats:a,x=y,-3=vivac:bad:b"))
    }

    @Test
    fun `a shortcut gets a glyph from what it says`() {
        assertEquals(ShortcutGlyph.VOICE, ShortcutGlyph.of("Chat de voz"))
        assertEquals(ShortcutGlyph.CAMERA, ShortcutGlyph.of("Cámara"))
        assertEquals(ShortcutGlyph.MIC, ShortcutGlyph.of("Dictado"))
        assertEquals(ShortcutGlyph.CODE, ShortcutGlyph.of("Code"))
        assertEquals(ShortcutGlyph.ASK, ShortcutGlyph.of("Pregunta a Claude"))
        assertEquals(ShortcutGlyph.ARROW, ShortcutGlyph.of("Otra cosa"))
    }
}
