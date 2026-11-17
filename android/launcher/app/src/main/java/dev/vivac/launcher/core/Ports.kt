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
    /** Android only shares app shortcuts with the default launcher. */
    fun canReadShortcuts(): Boolean
    fun openShortcut(packageName: String, id: String)
    fun showNotifications()
    fun notificationAccess()
    fun dotsAllowed(): Boolean
    fun systemSettings()
    fun securityUpdates()
    /** A short message on screen (a toast in production). */
    fun say(text: String)
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
