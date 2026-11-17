package dev.vivac.launcher.apps

/** A launchable app as the launcher sees it: what to show and what to start. */
data class InstalledApp(
    val label: String,
    val packageName: String,
    val isSystem: Boolean,
)

/** Port: where the installed apps come from (Android's LauncherApps in production). */
interface AppSource {
    fun installed(): List<InstalledApp>
}
