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

/** The phone's notifications, as a test sets them; what you do with them is recorded. */
class FakeNotices(avisos: List<dev.vivac.launcher.avisos.Aviso> = emptyList()) : Notices {
    val calls = mutableListOf<String>()
    var replies = true
    override val live = kotlinx.coroutines.flow.MutableStateFlow(avisos)
    override fun open(key: String) { calls += "open:$key" }
    override fun dismiss(key: String) { calls += "dismiss:$key"; live.value = live.value.filterNot { it.key == key } }
    override fun dismissAll() { calls += "dismissAll"; live.value = live.value.filterNot { it.clearable } }
    override fun reply(key: String, text: String): Boolean { calls += "reply:$key:$text"; return replies }
    var quietOn = false
    var quietWorks = true
    override fun quiet() = quietOn
    override fun setQuiet(on: Boolean): Boolean { calls += "quiet:$on"; if (quietWorks) quietOn = on; return quietWorks }
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
    var torchWorks = true
    override fun systemPage(page: SystemPage) { calls += "page:${page.name}" }
    override fun torch(on: Boolean): Boolean { calls += "torch:$on"; return torchWorks }
    var rotationOn = false
    var canWriteSettings = true
    override fun autoRotate() = rotationOn
    override fun setAutoRotate(on: Boolean): Boolean { calls += "rotate:$on"; if (canWriteSettings) rotationOn = on; return canWriteSettings }
    override fun notificationSettings(packageName: String) { calls += "noticeSettings:$packageName" }
    var level = 0.5f
    override fun brightness() = level
    override fun setBrightness(level: Float): Boolean { calls += "bright:$level"; if (canWriteSettings) this.level = level; return canWriteSettings }
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
    var packs = listOf<IconPackInfo>()
    override fun iconPacks() = packs
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

class FakeDirectory : Directory {
    val calls = mutableListOf<String>()
    var contactsAllowed = false
    var calendarAllowed = false
    var people = listOf<Contact>()
    var agenda = listOf<CalendarEvent>()
    override fun canReadContacts() = contactsAllowed
    override fun canReadCalendar() = calendarAllowed
    override fun contacts(query: String) = people.filter { it.name.contains(query, ignoreCase = true) }
    override fun events(query: String) = agenda.filter { it.title.contains(query, ignoreCase = true) }
    override fun openContact(contact: Contact) { calls += "contact:${contact.id}" }
    override fun openEvent(event: CalendarEvent) { calls += "event:${event.id}" }
    override fun askContacts() { calls += "askContacts" }
    override fun askCalendar() { calls += "askCalendar" }
}

