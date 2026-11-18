package dev.vivac.launcher.core

import dev.vivac.launcher.petate.AppShortcut
import dev.vivac.launcher.widgets.WidgetOption

/** Port: where vivac keeps its layout between runs (SharedPreferences in production). */
interface Store {
    fun get(key: String): String?
    fun put(changes: Map<String, String>)
}

/** Port: everything vivac asks Android to do on your behalf. */
interface Actions {
    fun open(packageName: String)
    fun info(packageName: String)
    fun uninstall(packageName: String)
    fun shortcuts(packageName: String): List<AppShortcut>
    /** Every app's shortcuts, by package, for the Petate's search (empty unless vivac is the home app). */
    fun allShortcuts(): List<Pair<String, AppShortcut>>
    /** Android only shares app shortcuts with the default launcher. */
    fun canReadShortcuts(): Boolean
    fun openShortcut(packageName: String, id: String)
    /** Starts an app in another profile ([Profile.id]). */
    fun openInProfile(packageName: String, profile: Long)
    /** Pauses or resumes a work profile, locks or unlocks the private space (Android asks for the credential). */
    fun lockProfile(profile: Long, locked: Boolean)
    /** Tells Android which of [packageName]'s shortcuts vivac keeps on the home screen (all of them, each time). */
    fun pinShortcuts(packageName: String, ids: List<String>)
    fun showNotifications()
    fun notificationAccess()
    fun dotsAllowed(): Boolean
    fun systemSettings()
    fun securityUpdates()
    /** A short message on screen (a toast in production). */
    fun say(text: String)
    /** Puts [text] on the clipboard (Android shows its own confirmation). */
    fun copy(text: String)
    /** Turns the screen off through vivac's accessibility service; false when that service is not on. */
    fun lockScreen(): Boolean
    /** Android's accessibility page, where vivac's lock service is switched on. */
    fun accessibilitySettings()
    fun lockScreenReady(): Boolean
    /** Whether vivac is the phone's home app (Android's home role). */
    fun isHome(): Boolean
    /** Android's own dialog to make vivac the home app. */
    fun askToBeHome()
    /** Android's "save as" screen for a copy of the camp; the activity writes it when you choose the place. */
    fun backUp()
    /** Android's file picker for a copy to restore. */
    fun pickBackup()
    /** The web search app you use (or the browser), for [query]. */
    fun webSearch(query: String)
    /** The app store you use (any that answers market:// links), for [query]. */
    fun storeSearch(query: String)
}

/** Port: the app-widget host. Ids are Android's; [WidgetOption.key] names the provider. */
interface WidgetHost {
    fun options(): List<WidgetOption>
    fun allocate(): Int
    /** True when Android lets vivac place it without asking (a past "always allow"). */
    fun bindIfAllowed(id: Int, option: WidgetOption): Boolean
    /** Shows the system dialog; the answer comes back through [Launcher.onWidgetResult]. */
    fun requestBind(id: Int, option: WidgetOption)
    fun needsConfiguring(id: Int): Boolean
    /** Starts the widget's own setup screen; the answer comes back through [Launcher.onWidgetResult]. */
    fun requestConfigure(id: Int)
    fun delete(id: Int)
    fun exists(id: Int): Boolean
    fun label(id: Int): String
    /** The rows a widget fills at its own size, before you choose one. */
    fun defaultRows(id: Int): Int
}
