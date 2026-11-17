package dev.vivac.launcher.campamento

/** A change to the home layout: the new layout, or why it was refused. */
data class HomeChange(val home: Home?, val refusal: String? = null)

/** What you chose for the Campamento: the dock's apps and the apps pinned "a mano". */
data class Home(
    val dock: List<String> = emptyList(),
    val pinned: List<String> = emptyList(),
) {
    fun toggleDock(packageName: String): HomeChange = when {
        packageName in dock -> HomeChange(copy(dock = dock - packageName))
        dock.size >= DOCK_MAX -> HomeChange(null, "El dock ya tiene $DOCK_MAX apps: quita una primero.")
        else -> HomeChange(copy(dock = dock + packageName))
    }

    fun togglePin(packageName: String): HomeChange = when {
        packageName in pinned -> HomeChange(copy(pinned = pinned - packageName))
        pinned.size >= PINNED_MAX -> HomeChange(null, "El campamento ya tiene $PINNED_MAX apps a mano: quita una primero.")
        else -> HomeChange(copy(pinned = pinned + packageName))
    }

    /** Forget apps that are no longer installed. */
    fun keepOnly(installed: Set<String>) = Home(dock.filter { it in installed }, pinned.filter { it in installed })

    fun encodeDock(): String = dock.joinToString(SEP)
    fun encodePinned(): String = pinned.joinToString(SEP)

    companion object {
        const val DOCK_MAX = 4
        const val PINNED_MAX = 8
        // Package names never contain a comma, so it is a safe separator.
        private const val SEP = ","

        fun decode(dock: String?, pinned: String?) = Home(split(dock), split(pinned))

        private fun split(raw: String?) = raw.orEmpty().split(SEP).filter { it.isNotBlank() }
    }
}
