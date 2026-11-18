package dev.vivac.launcher.campamento

/** A change to the home layout: the new layout, or why it was refused. */
data class HomeChange(val home: Home?, val refusal: String? = null)

/** What you chose for the Campamento: the dock's apps and the apps pinned "a mano". */
data class Home(
    val dock: List<String> = emptyList(),
    val pinned: List<String> = emptyList(),
    /** Apps kept out of the Petate (and so out of the dock and pins too). */
    val hidden: List<String> = emptyList(),
    /** You have set the dock yourself (even to nothing); until then it shows the default favourites. */
    val dockChosen: Boolean = dock.isNotEmpty(),
) {
    fun toggleDock(packageName: String): HomeChange = when {
        packageName in dock -> HomeChange(copy(dock = dock - packageName, dockChosen = true))
        dock.size >= DOCK_MAX -> HomeChange(null, "El dock ya tiene $DOCK_MAX apps: quita una primero.")
        else -> HomeChange(copy(dock = dock + packageName, dockChosen = true))
    }

    fun togglePin(packageName: String): HomeChange = when {
        packageName in pinned -> HomeChange(copy(pinned = pinned - packageName))
        pinned.size >= PINNED_MAX -> HomeChange(null, "El campamento ya tiene $PINNED_MAX apps a mano: quita una primero.")
        else -> HomeChange(copy(pinned = pinned + packageName))
    }

    /** Hiding takes the app off the dock and the pins; showing it again just brings it back to the Petate. */
    fun toggleHidden(packageName: String): Home =
        if (packageName in hidden) copy(hidden = hidden - packageName)
        else copy(dock = dock - packageName, pinned = pinned - packageName, hidden = hidden + packageName)

    /** Forget apps that are no longer installed. */
    fun keepOnly(installed: Set<String>) =
        copy(dock = dock.filter { it in installed }, pinned = pinned.filter { it in installed }, hidden = hidden.filter { it in installed })

    fun encodeDock(): String = dock.joinToString(SEP)
    /** What to store for the dock: nothing until you chose one, so the default favourites keep applying. */
    fun storedDock(): String? = if (dockChosen) encodeDock() else null
    fun encodePinned(): String = pinned.joinToString(SEP)
    fun encodeHidden(): String = hidden.joinToString(SEP)

    companion object {
        const val DOCK_MAX = 5
        const val PINNED_MAX = 8
        // Package names never contain a comma, so it is a safe separator.
        private const val SEP = ","

        /** A stored dock, even an empty one, is a dock you chose; no stored dock means the default favourites. */
        fun decode(dock: String?, pinned: String?, hidden: String? = null) = Home(split(dock), split(pinned), split(hidden), dockChosen = dock != null)

        private fun split(raw: String?) = raw.orEmpty().split(SEP).filter { it.isNotBlank() }
    }
}
