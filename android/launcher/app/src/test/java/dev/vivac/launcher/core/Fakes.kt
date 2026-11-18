package dev.vivac.launcher.core

import dev.vivac.launcher.apps.AppSource
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.petate.AppShortcut
import dev.vivac.launcher.widgets.WidgetOption

class FakeSource(var apps: List<InstalledApp>, var others: List<dev.vivac.launcher.apps.Profile> = emptyList()) : AppSource {
    override fun installed() = apps
    override fun profiles() = others
}

class FakeStore(val values: MutableMap<String, String> = mutableMapOf()) : Store {
    override fun get(key: String) = values[key]
    override fun put(changes: Map<String, String>) { values += changes }
}

/** Records every request vivac hands to Android, so tests can check what would have happened. */
class FakeActions : Actions {
    val calls = mutableListOf<String>()
    var shortcuts = mapOf<String, List<AppShortcut>>()
    var shortcutsReadable = true
    var dotsOn = false
    override fun open(packageName: String) { calls += "open:$packageName" }
    override fun info(packageName: String) { calls += "info:$packageName" }
    override fun uninstall(packageName: String) { calls += "uninstall:$packageName" }
    override fun shortcuts(packageName: String) = shortcuts[packageName].orEmpty()
    override fun canReadShortcuts() = shortcutsReadable
    override fun openShortcut(packageName: String, id: String) { calls += "shortcut:$packageName/$id" }
    override fun showNotifications() { calls += "notifications" }
    override fun notificationAccess() { calls += "notificationAccess" }
    override fun dotsAllowed() = dotsOn
    override fun systemSettings() { calls += "settings" }
    override fun securityUpdates() { calls += "about" }
    override fun say(text: String) { calls += "say:$text" }
    override fun copy(text: String) { calls += "copy:$text" }
    var lockService = false
    override fun lockScreen(): Boolean { if (lockService) calls += "lock"; return lockService }
    override fun accessibilitySettings() { calls += "accessibility" }
    override fun lockScreenReady() = lockService
    var home = true
    override fun isHome() = home
    override fun askToBeHome() { calls += "askHome" }
    override fun backUp() { calls += "backup" }
    override fun pickWallpaper() { calls += "wallpaper" }
    override fun openInProfile(packageName: String, profile: Long) { calls += "openIn:$profile:$packageName" }
    override fun lockProfile(profile: Long, locked: Boolean) { calls += "lockProfile:$profile:$locked" }
    var allShortcuts = listOf<Pair<String, AppShortcut>>()
    override fun allShortcuts() = allShortcuts
    override fun pickBackup() { calls += "restore" }
    override fun webSearch(query: String) { calls += "web:$query" }
    override fun storeSearch(query: String) { calls += "store:$query" }
    override fun pinShortcuts(packageName: String, ids: List<String>) { calls += "pinShortcuts:$packageName:$ids" }
}

class FakeWidgets : WidgetHost {
    val calls = mutableListOf<String>()
    var offered = listOf<WidgetOption>()
    var placed = mutableMapOf<Int, String>()
    var allowed = true
    var configurable = setOf<String>()
    private var next = 1
    private val bound = mutableMapOf<Int, WidgetOption>()
    override fun options() = offered
    override fun allocate() = next++
    override fun bindIfAllowed(id: Int, option: WidgetOption): Boolean {
        if (allowed) bind(id, option)
        return allowed
    }
    override fun requestBind(id: Int, option: WidgetOption) { calls += "askBind:$id"; bound[id] = option }
    override fun needsConfiguring(id: Int) = (placed[id] ?: bound[id]?.key) in configurable
    override fun requestConfigure(id: Int) { calls += "configure:$id" }
    override fun delete(id: Int) { calls += "delete:$id"; placed.remove(id) }
    override fun exists(id: Int) = id in placed
    override fun label(id: Int) = placed[id] ?: "widget"
    var rows = mutableMapOf<Int, Int>()
    override fun defaultRows(id: Int) = rows[id] ?: 2
    fun bind(id: Int, option: WidgetOption) { placed[id] = option.key }
    /** What Android does when you accept the bind dialog. */
    fun accept(id: Int) { bound[id]?.let { bind(id, it) } }
}
