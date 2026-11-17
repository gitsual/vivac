package dev.vivac.launcher.apps

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.LauncherApps
import android.net.Uri
import android.os.Process
import android.os.UserHandle
import android.provider.Settings
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

/** Starting apps, their shortcuts and their system pages. */
class AppActions(private val context: Context) {
    private val launcherApps = context.getSystemService(LauncherApps::class.java)

    /**
     * The app's own shortcuts, by rank. Android only shares them with the default launcher,
     * so this is empty until vivac is chosen as the home app.
     */
    fun canReadShortcuts(): Boolean = launcherApps.hasShortcutHostPermission()

    fun shortcuts(packageName: String): List<AppShortcut> {
        if (!canReadShortcuts()) return emptyList()
        val query = LauncherApps.ShortcutQuery()
            .setPackage(packageName)
            .setQueryFlags(LauncherApps.ShortcutQuery.FLAG_MATCH_DYNAMIC or LauncherApps.ShortcutQuery.FLAG_MATCH_MANIFEST)
        return runCatching { launcherApps.getShortcuts(query, Process.myUserHandle()).orEmpty() }
            .getOrDefault(emptyList())
            .sortedBy { it.rank }
            .map { AppShortcut(it.id, it.shortLabel?.toString().orEmpty()) }
    }

    fun openShortcut(packageName: String, id: String): Boolean = runCatching {
        launcherApps.startShortcut(packageName, id, null, null, Process.myUserHandle())
        true
    }.getOrDefault(false)

    /** Hands over to the system's uninstall confirmation; vivac never removes anything by itself. */
    fun uninstall(packageName: String): Boolean =
        start(Intent(Intent.ACTION_DELETE, Uri.fromParts("package", packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    fun open(packageName: String): Boolean {
        val intent = context.packageManager.getLaunchIntentForPackage(packageName) ?: return false
        return start(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun info(packageName: String): Boolean =
        start(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

    /**
     * Pulls down the notification shade. There is no public API for it: every launcher
     * calls StatusBarManager.expandNotificationsPanel (needs EXPAND_STATUS_BAR).
     */
    @android.annotation.SuppressLint("WrongConstant")
    fun showNotifications(): Boolean = runCatching {
        val bar = context.getSystemService("statusbar") ?: return false
        bar.javaClass.getMethod("expandNotificationsPanel").invoke(bar)
        true
    }.getOrDefault(false)

    fun systemSettings(): Boolean = start(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

    fun securityUpdates(): Boolean = start(Intent(Settings.ACTION_DEVICE_INFO_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

    private fun start(intent: Intent): Boolean = try {
        context.startActivity(intent)
        true
    } catch (_: ActivityNotFoundException) {
        false
    }
}
