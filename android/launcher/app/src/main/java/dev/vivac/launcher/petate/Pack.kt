package dev.vivac.launcher.petate

import dev.vivac.launcher.apps.InstalledApp
import java.text.Collator
import java.text.Normalizer
import java.util.Locale

/** The Petate's three shelves, in the order they are shown. */
enum class Group(val title: String, val caption: String) {
    INFRA("Infra", "control del campamento"),
    DAILY("Día a día", "lo de cada día"),
    SYSTEM("Sistema", "grapheneos"),
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

    fun search(apps: List<InstalledApp>, query: String): List<InstalledApp> {
        val needle = fold(query.trim())
        if (needle.isEmpty()) return apps
        return apps.filter { fold(it.label).contains(needle) }
    }

    /** Groups in fixed order, each sorted alphabetically in Spanish; empty groups are left out. */
    fun grouped(apps: List<InstalledApp>, filter: Group?): List<Pair<Group, List<InstalledApp>>> =
        Group.entries
            .filter { filter == null || it == filter }
            .map { group -> group to apps.filter { groupOf(it) == group }.sortedWith(compareBy(collator) { it.label }) }
            .filter { it.second.isNotEmpty() }

    fun summary(apps: List<InstalledApp>): String {
        val google = apps.count { app -> googlePrefixes.any { app.packageName.startsWith(it) } }
        val noun = if (apps.size == 1) "app" else "apps"
        return "${apps.size} $noun · $google de Google"
    }

    /** A stable colour slot per package, so a tile keeps its colour across label or locale changes. */
    fun toneIndex(app: InstalledApp, paletteSize: Int): Int = Math.floorMod(app.packageName.hashCode(), paletteSize)

    private fun fold(text: String): String =
        Normalizer.normalize(text, Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase(Locale.ROOT)
}
