package dev.vivac.launcher.apps

import org.junit.Assert.assertEquals
import org.junit.Test

class DotsTest {
    private fun n(pkg: String, ongoing: Boolean = false, badge: Boolean = true, summary: Boolean = false) =
        Notice(pkg, ongoing = ongoing, canShowBadge = badge, isGroupSummary = summary)

    @Test
    fun `apps with a regular notification get a dot`() {
        assertEquals(setOf("com.whatsapp", "org.telegram.messenger"), Dots.of(listOf(n("com.whatsapp"), n("org.telegram.messenger"), n("com.whatsapp"))))
    }

    @Test
    fun `ongoing ones (music, downloads, VPN) never make a dot`() {
        assertEquals(emptySet<String>(), Dots.of(listOf(n("com.spotify.music", ongoing = true))))
    }

    @Test
    fun `channels that opted out of badges are respected`() {
        assertEquals(emptySet<String>(), Dots.of(listOf(n("com.ubercab", badge = false))))
    }

    @Test
    fun `a lone group summary does not count, its children do`() {
        assertEquals(emptySet<String>(), Dots.of(listOf(n("com.google.android.gm", summary = true))))
        assertEquals(setOf("com.google.android.gm"), Dots.of(listOf(n("com.google.android.gm", summary = true), n("com.google.android.gm"))))
    }
}
