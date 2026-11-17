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

/** Starting apps and their system info page. */
class AppActions(private val context: Context) {
    fun open(packageName: String): Boolean {
        val intent = context.packageManager.getLaunchIntentForPackage(packageName) ?: return false
        return start(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun info(packageName: String): Boolean =
        start(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

    fun systemSettings(): Boolean = start(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

    fun securityUpdates(): Boolean = start(Intent(Settings.ACTION_DEVICE_INFO_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

    private fun start(intent: Intent): Boolean = try {
        context.startActivity(intent)
        true
    } catch (_: ActivityNotFoundException) {
        false
    }
}
