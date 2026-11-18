package dev.vivac.launcher.apps

/** A launchable app as the launcher sees it: what to show and what to start. */
data class InstalledApp(
    val label: String,
    val packageName: String,
    val isSystem: Boolean,
)

/** Another profile on the phone: a work profile, or Android 15's private space. */
data class Profile(
    /** Android's serial number for the profile; it names it to [dev.vivac.launcher.core.Actions]. */
    val id: Long,
    val kind: Kind,
    /** Paused (work) or locked (private space): its apps cannot run and the private space shows none. */
    val locked: Boolean,
    val apps: List<InstalledApp>,
) {
    enum class Kind(val title: String) { WORK("Trabajo"), PRIVATE("Privado") }
}

/** Port: where the installed apps come from (Android's LauncherApps in production). */
interface AppSource {
    fun installed(): List<InstalledApp>
    /** The phone's other profiles, if any. */
    fun profiles(): List<Profile> = emptyList()
}
