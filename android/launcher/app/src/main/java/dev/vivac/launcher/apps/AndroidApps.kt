package dev.vivac.launcher.apps

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.LauncherApps
import android.content.pm.ShortcutInfo
import android.net.Uri
import android.os.Process
import android.os.UserHandle
import android.provider.Settings
import dev.vivac.launcher.core.Actions
import dev.vivac.launcher.petate.AppShortcut

/** Adapter: installed apps of the current profile, read from LauncherApps. */
class AndroidAppSource(private val context: Context) : AppSource {
    private val launcherApps = context.getSystemService(LauncherApps::class.java)

    override fun installed(): List<InstalledApp> =
        launcherApps.getActivityList(null, Process.myUserHandle())
            .filter { it.applicationInfo.packageName != context.packageName }
            .map {
                InstalledApp(
                    label = it.label.toString(),
                    packageName = it.applicationInfo.packageName,
                    isSystem = it.applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM != 0,
                )
            }
            .distinctBy { it.packageName }

    /** Calls [onChange] with the package whenever an app is installed, removed or updated. */
    fun watch(onChange: (packageName: String) -> Unit): LauncherApps.Callback {
        val callback = object : LauncherApps.Callback() {
            override fun onPackageRemoved(packageName: String, user: UserHandle) = onChange(packageName)
            override fun onPackageAdded(packageName: String, user: UserHandle) = onChange(packageName)
            override fun onPackageChanged(packageName: String, user: UserHandle) = onChange(packageName)
            override fun onPackagesAvailable(packageNames: Array<out String>, user: UserHandle, replacing: Boolean) = packageNames.forEach(onChange)
            override fun onPackagesUnavailable(packageNames: Array<out String>, user: UserHandle, replacing: Boolean) = packageNames.forEach(onChange)
        }
        launcherApps.registerCallback(callback)
        return callback
    }

    fun unwatch(callback: LauncherApps.Callback) = launcherApps.unregisterCallback(callback)
}

/** Adapter: starting apps, their shortcuts and their system pages. */
class AppActions(private val context: Context) : Actions {
    private val launcherApps = context.getSystemService(LauncherApps::class.java)

    /**
     * The app's own shortcuts, by rank. Android only shares them with the default launcher,
     * so this is empty until vivac is chosen as the home app.
     */
    override fun canReadShortcuts(): Boolean = launcherApps.hasShortcutHostPermission()

    override fun shortcuts(packageName: String): List<AppShortcut> {
        if (!canReadShortcuts()) return emptyList()
        val query = LauncherApps.ShortcutQuery()
            .setPackage(packageName)
            .setQueryFlags(LauncherApps.ShortcutQuery.FLAG_MATCH_DYNAMIC or LauncherApps.ShortcutQuery.FLAG_MATCH_MANIFEST)
        return ordered(runCatching { launcherApps.getShortcuts(query, Process.myUserHandle()).orEmpty() }.getOrDefault(emptyList()))
    }

    companion object {
        /**
         * Ranks are counted separately for manifest and dynamic shortcuts; like the Pixel launcher,
         * the app's declared ones come first.
         */
        fun ordered(shortcuts: List<ShortcutInfo>): List<AppShortcut> =
            shortcuts.sortedWith(compareBy<ShortcutInfo>({ !it.isDeclaredInManifest }, { it.rank }))
                .map { AppShortcut(it.id, it.shortLabel?.toString().orEmpty()) }
    }

    override fun openShortcut(packageName: String, id: String) {
        runCatching { launcherApps.startShortcut(packageName, id, null, null, Process.myUserHandle()) }
    }

    override fun pinShortcuts(packageName: String, ids: List<String>) {
        runCatching { launcherApps.pinShortcuts(packageName, ids, Process.myUserHandle()) }
    }

    /** Hands over to the system's uninstall confirmation; vivac never removes anything by itself. */
    override fun uninstall(packageName: String) {
        start(Intent(Intent.ACTION_DELETE, Uri.fromParts("package", packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
    override fun open(packageName: String) {
        val intent = context.packageManager.getLaunchIntentForPackage(packageName) ?: return
        start(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    override fun info(packageName: String) {
        start(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /**
     * Pulls down the notification shade. There is no public API for it: every launcher
     * calls StatusBarManager.expandNotificationsPanel (needs EXPAND_STATUS_BAR).
     */
    @android.annotation.SuppressLint("WrongConstant")
    override fun showNotifications() {
        runCatching {
            val bar = context.getSystemService("statusbar") ?: return
            bar.javaClass.getMethod("expandNotificationsPanel").invoke(bar)
        }
    }

    /** The system page where you allow (or revoke) vivac's notification access for the dots. */
    override fun notificationAccess() {
        val me = android.content.ComponentName(context, DotsListener::class.java)
        val detail = Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
            .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, me.flattenToString())
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (!start(detail)) start(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    override fun dotsAllowed(): Boolean = DotsListener.isAllowed(context)

    override fun say(text: String) = android.widget.Toast.makeText(context, text, android.widget.Toast.LENGTH_LONG).show()

    /** A search app if there is one; else the browser on DuckDuckGo (GrapheneOS ships no Google search). */
    override fun webSearch(query: String) {
        val search = Intent(Intent.ACTION_WEB_SEARCH).putExtra(android.app.SearchManager.QUERY, query).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (search.resolveActivity(context.packageManager) != null && start(search)) return
        start(Intent(Intent.ACTION_VIEW, Uri.parse("https://duckduckgo.com/?q=" + Uri.encode(query))).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    override fun storeSearch(query: String) {
        if (!start(Intent(Intent.ACTION_VIEW, Uri.parse("market://search?q=" + Uri.encode(query))).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))) {
            say("No hay ninguna tienda de apps instalada.")
        }
    }

    override fun lockScreen(): Boolean = LockService.lock()

    override fun lockScreenReady(): Boolean = LockService.running

    override fun accessibilitySettings() {
        start(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    override fun copy(text: String) {
        context.getSystemService(android.content.ClipboardManager::class.java)
            .setPrimaryClip(android.content.ClipData.newPlainText("vivac", text))
    }

    override fun systemSettings() {
        start(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    override fun securityUpdates() {
        start(Intent(Settings.ACTION_DEVICE_INFO_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /** True when some app took the intent. */
    private fun start(intent: Intent): Boolean = try {
        context.startActivity(intent)
        true
    } catch (_: ActivityNotFoundException) {
        false
    }
}
