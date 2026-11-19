package dev.vivac.launcher.petate

import dev.vivac.launcher.apps.InstalledApp
import java.text.Collator
import java.text.Normalizer
import java.util.Locale

/** An app's shortcut, as the Petate's search finds it. */
data class FoundShortcut(val app: InstalledApp, val shortcut: AppShortcut)

/** The Petate's three shelves, in the order they are shown. */
enum class Group(val title: String) {
    INFRA("Infra"),
    DAILY("Día a día"),
    SYSTEM("Sistema"),
}

/** Pure rules of the Petate (the app drawer): grouping, monograms, search, summary. */
object Pack {
    /** Packages that run the camp: the vivac stack and what keeps the rope tied. */
    private val infraPrefixes = listOf(
        "dev.vivac.",
        "com.termux",
        "com.tailscale.",
        "org.localsend.",
        "com.kunzisoft.keepass",
        "io.heckel.ntfy",
        "de.nulide.findmydevice",
    )

    /** GrapheneOS' own apps update from its store, so Android stops flagging them as system apps. */
    private val grapheneosPrefixes = listOf("app.grapheneos.", "app.attestation.", "app.vanadium.")

    private val monogramOverrides = mapOf("com.termux" to ">_")

    private val googlePrefixes = listOf("com.google.", "com.android.vending", "com.android.chrome")

    private val collator: Collator = Collator.getInstance(Locale.forLanguageTag("es-ES")).apply {
        strength = Collator.PRIMARY
    }

    fun groupOf(app: InstalledApp): Group = when {
        infraPrefixes.any { app.packageName == it.trimEnd('.') || app.packageName.startsWith(it) } -> Group.INFRA
        app.isSystem || grapheneosPrefixes.any { app.packageName.startsWith(it) } -> Group.SYSTEM
        else -> Group.DAILY
    }

    /** Two letters for the tile: first letters of two words, else a first letter plus an inner capital, else the first two. */
    fun monogram(app: InstalledApp): String {
        monogramOverrides[app.packageName]?.let { return it }
        val words = app.label.trim().split(Regex("[\\s:·-]+")).filter { it.isNotEmpty() && it.first().isLetterOrDigit() }
        val first = words.firstOrNull() ?: return "?"
        val head = first.first().uppercaseChar()
        val second = when {
            words.size > 1 -> words[1].first()
            else -> first.drop(1).firstOrNull { it.isUpperCase() } ?: first.getOrNull(1)
        }
        return if (second == null) "$head" else "$head${second.lowercaseChar()}"
    }

    /** The Petate shows either the apps you did not hide, or, when you ask for them, only the hidden ones. */
    fun visible(apps: List<InstalledApp>, hidden: Set<String>, showHidden: Boolean): List<InstalledApp> =
        apps.filter { (it.packageName in hidden) == showHidden }

    /** Matches the label anywhere, or its initials from the start ("om" finds Organic Maps). */
    fun search(apps: List<InstalledApp>, query: String): List<InstalledApp> {
        val needle = fold(query.trim())
        if (needle.isEmpty()) return apps
        val exact = apps.filter { fold(it.label).contains(needle) || initials(it.label).startsWith(needle) }
        if (exact.isNotEmpty()) return exact
        // Nothing matches as typed: allow a slip (one letter, two for long words) on searches of five letters or more.
        if (needle.length < 5) return emptyList()
        val slips = if (needle.length >= 8) 2 else 1
        return apps.filter { app -> fold(app.label).split(' ').any { word -> near(needle, word, slips) } }
    }

    /** The app shortcuts whose own name holds [query]. */
    fun searchShortcuts(shortcuts: List<FoundShortcut>, query: String): List<FoundShortcut> {
        val needle = fold(query.trim())
        if (needle.isEmpty()) return emptyList()
        return shortcuts.filter { fold(it.shortcut.label).contains(needle) }
    }

    /** Android's `ApplicationInfo.CATEGORY_*` (0 games .. 8 accessibility), named for the petate's chips. */
    private val androidCategories = listOf("Juegos", "Música", "Vídeo", "Fotos", "Social", "Noticias", "Mapas", "Productividad", "Accesibilidad")

    fun androidCategory(code: Int): String? = androidCategories.getOrNull(code)

    /** The categories among [apps], once each (case aside), in alphabetical order. */
    fun categories(apps: List<InstalledApp>): List<String> =
        apps.mapNotNull { it.category?.trim()?.takeIf(String::isNotEmpty) }.distinctBy { fold(it) }.sortedWith(collator)

    /**
     * Android's settings pages whose name or contents hold [query], names first, at most four. Letters and digits
     * only, so "wifi" finds "Wi-Fi".
     */
    fun searchSettings(query: String): List<dev.vivac.launcher.core.SystemPage> {
        val needle = bare(query)
        if (needle.isEmpty()) return emptyList()
        val pages = dev.vivac.launcher.core.SystemPage.entries
        val byName = pages.filter { bare(it.title).contains(needle) }
        val byContents = pages.filter { it !in byName && bare(it.detail).contains(needle) }
        return (byName + byContents).take(4)
    }

    private fun bare(text: String) = fold(text).filter { it.isLetterOrDigit() }

    /** [needle] is within [slips] edits (a swap counts as one) of how [word] starts. */
    private fun near(needle: String, word: String, slips: Int): Boolean =
        (needle.length - 1..needle.length + 1).any { n -> n in 1..word.length && distance(needle, word.take(n)) <= slips }

    /** Optimal string alignment distance: insertions, deletions, substitutions and swaps of neighbours. */
    private fun distance(a: String, b: String): Int {
        val d = Array(a.length + 1) { i -> IntArray(b.length + 1) { j -> if (i == 0) j else if (j == 0) i else 0 } }
        for (i in 1..a.length) for (j in 1..b.length) {
            val cost = if (a[i - 1] == b[j - 1]) 0 else 1
            d[i][j] = minOf(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
            if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) d[i][j] = minOf(d[i][j], d[i - 2][j - 2] + 1)
        }
        return d[a.length][b.length]
    }

    /** First letter of each word, plus every inner capital: "KeePassDX" gives "kpdx". */
    private fun initials(label: String): String =
        label.split(Regex("[\\s:·-]+")).filter { it.isNotEmpty() }.joinToString("") { word ->
            "${word.first()}${word.drop(1).filter { it.isUpperCase() }}"
        }.let(::fold)

    /** The altimeter letter an app files under: its folded first letter, or '#' for anything else. */
    fun initialOf(app: InstalledApp): Char =
        fold(app.label.trim()).firstOrNull()?.takeIf { it in 'a'..'z' }?.uppercaseChar() ?: '#'

    /** For each letter, the position of its first app in the Petate's grid, where each shelf header is one item. */
    fun jumps(shelves: List<Pair<Group, List<InstalledApp>>>): Map<Char, Int> {
        val jumps = linkedMapOf<Char, Int>()
        var index = 0
        shelves.forEach { (_, apps) ->
            index++ // the shelf header
            apps.forEach { app -> jumps.putIfAbsent(initialOf(app), index); index++ }
        }
        return jumps
    }

    /** Groups in fixed order, each sorted alphabetically in Spanish; empty groups are left out. */
    fun grouped(apps: List<InstalledApp>, filter: Group?): List<Pair<Group, List<InstalledApp>>> =
        Group.entries
            .filter { filter == null || it == filter }
            .map { group -> group to apps.filter { groupOf(it) == group }.sortedWith(compareBy(collator) { it.label }) }
            .filter { it.second.isNotEmpty() }


    /** A stable colour slot per package, so a tile keeps its colour across label or locale changes. */
    fun toneIndex(app: InstalledApp, paletteSize: Int): Int = Math.floorMod(app.packageName.hashCode(), paletteSize)

    private fun fold(text: String): String =
        Normalizer.normalize(text, Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase(Locale.ROOT)
}
