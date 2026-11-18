package dev.vivac.launcher.apps

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.LauncherApps
import android.content.pm.ShortcutInfo
import android.net.Uri
import android.os.Build
import android.os.Process
import android.os.UserHandle
import android.provider.Settings
import dev.vivac.launcher.core.Actions
import dev.vivac.launcher.petate.AppShortcut

/** Adapter: installed apps of the current profile, read from LauncherApps. */
/** UserManager.USER_TYPE_PROFILE_PRIVATE (Android 15). */
private const val USER_TYPE_PRIVATE = "android.os.usertype.profile.PRIVATE"

class AndroidAppSource(private val context: Context) : AppSource {
    private val launcherApps = context.getSystemService(LauncherApps::class.java)

    private val users = context.getSystemService(android.os.UserManager::class.java)

    override fun installed(): List<InstalledApp> = appsOf(Process.myUserHandle())

    /**
     * Every profile besides the main one. Android 15 shows the private space only to the home app that declares
     * ACCESS_HIDDEN_PROFILES; a locked private space lists no apps.
     */
    override fun profiles(): List<Profile> = launcherApps.profiles.filter { it != Process.myUserHandle() }.map { user ->
        val kind = if (userType(user) == USER_TYPE_PRIVATE) Profile.Kind.PRIVATE else Profile.Kind.WORK
        val locked = users.isQuietModeEnabled(user)
        Profile(users.getSerialNumberForUser(user), kind, locked, if (locked && kind == Profile.Kind.PRIVATE) emptyList() else appsOf(user))
    }

    /**
     * LauncherApps.getLauncherUserInfo(user).userType, Android 15+. vivac compiles against Android 14,
     * so it is reached by name; older Androids have no private space and answer null.
     */
    private fun userType(user: UserHandle): String? = runCatching {
        val info = LauncherApps::class.java.getMethod("getLauncherUserInfo", UserHandle::class.java).invoke(launcherApps, user)
        info?.javaClass?.getMethod("getUserType")?.invoke(info) as String?
    }.getOrNull()

    private fun appsOf(user: UserHandle): List<InstalledApp> =
        launcherApps.getActivityList(null, user)
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
    private val users = context.getSystemService(android.os.UserManager::class.java)

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

    override fun allShortcuts(): List<Pair<String, AppShortcut>> {
        if (!canReadShortcuts()) return emptyList()
        val query = LauncherApps.ShortcutQuery()
            .setQueryFlags(LauncherApps.ShortcutQuery.FLAG_MATCH_DYNAMIC or LauncherApps.ShortcutQuery.FLAG_MATCH_MANIFEST)
        val all = runCatching { launcherApps.getShortcuts(query, Process.myUserHandle()).orEmpty() }.getOrDefault(emptyList())
        return all.groupBy { it.`package` }.flatMap { (pkg, list) -> ordered(list).map { pkg to it } }
    }

    companion object {
        const val REQ_HOME = 7003
        const val REQ_BACKUP = 7004
        const val REQ_RESTORE = 7005
        /**
         * Ranks are counted separately for manifest and dynamic shortcuts; like the Pixel launcher,
         * the app's declared ones come first.
         */
        fun ordered(shortcuts: List<ShortcutInfo>): List<AppShortcut> =
            shortcuts.sortedWith(compareBy<ShortcutInfo>({ !it.isDeclaredInManifest }, { it.rank }))
                .map { AppShortcut(it.id, it.shortLabel?.toString().orEmpty()) }
    }

    override fun openInProfile(packageName: String, profile: Long) {
        val user = users.getUserForSerialNumber(profile) ?: return
        val activity = launcherApps.getActivityList(packageName, user).firstOrNull() ?: return
        runCatching { launcherApps.startMainActivity(activity.componentName, user, null, null) }
    }

    /** Pausing a work profile, or locking the private space; unlocking asks for its credential. */
    override fun lockProfile(profile: Long, locked: Boolean) {
        val user = users.getUserForSerialNumber(profile) ?: return
        runCatching { users.requestQuietModeEnabled(locked, user) }
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

    /** The settings page or panel for [page]; Android's whole Settings app if this phone has no such page. */
    override fun systemPage(page: dev.vivac.launcher.core.SystemPage) {
        val action = when (page) {
            dev.vivac.launcher.core.SystemPage.INTERNET -> Settings.Panel.ACTION_INTERNET_CONNECTIVITY
            dev.vivac.launcher.core.SystemPage.VOLUMEN -> Settings.Panel.ACTION_VOLUME
            dev.vivac.launcher.core.SystemPage.WIFI -> Settings.Panel.ACTION_WIFI
            dev.vivac.launcher.core.SystemPage.DATOS -> Settings.ACTION_NETWORK_OPERATOR_SETTINGS
            dev.vivac.launcher.core.SystemPage.AVION -> Settings.ACTION_AIRPLANE_MODE_SETTINGS
            dev.vivac.launcher.core.SystemPage.ALARMAS -> android.provider.AlarmClock.ACTION_SHOW_ALARMS
            dev.vivac.launcher.core.SystemPage.AHORRO -> Settings.ACTION_BATTERY_SAVER_SETTINGS
            dev.vivac.launcher.core.SystemPage.PRIVACIDAD -> "android.settings.PRIVACY_CONTROLS"
            dev.vivac.launcher.core.SystemPage.ENVIAR -> Settings.ACTION_CAST_SETTINGS
            dev.vivac.launcher.core.SystemPage.COMPARTIR -> "android.settings.TETHER_SETTINGS"
            dev.vivac.launcher.core.SystemPage.NFC -> Settings.Panel.ACTION_NFC
            dev.vivac.launcher.core.SystemPage.TEMA -> "android.settings.DARK_THEME_SETTINGS"
            dev.vivac.launcher.core.SystemPage.LUZ -> Settings.ACTION_NIGHT_DISPLAY_SETTINGS
            dev.vivac.launcher.core.SystemPage.BLUETOOTH -> Settings.ACTION_BLUETOOTH_SETTINGS
            dev.vivac.launcher.core.SystemPage.PANTALLA -> Settings.ACTION_DISPLAY_SETTINGS
            dev.vivac.launcher.core.SystemPage.SONIDO -> Settings.ACTION_SOUND_SETTINGS
            dev.vivac.launcher.core.SystemPage.BATERIA -> Intent.ACTION_POWER_USAGE_SUMMARY
            dev.vivac.launcher.core.SystemPage.NOTIFICACIONES -> "android.settings.NOTIFICATION_SETTINGS"
            dev.vivac.launcher.core.SystemPage.APPS -> Settings.ACTION_APPLICATION_SETTINGS
            dev.vivac.launcher.core.SystemPage.ALMACENAMIENTO -> Settings.ACTION_INTERNAL_STORAGE_SETTINGS
            dev.vivac.launcher.core.SystemPage.SEGURIDAD -> Settings.ACTION_SECURITY_SETTINGS
            dev.vivac.launcher.core.SystemPage.UBICACION -> Settings.ACTION_LOCATION_SOURCE_SETTINGS
            dev.vivac.launcher.core.SystemPage.SISTEMA -> Settings.ACTION_LOCALE_SETTINGS
            dev.vivac.launcher.core.SystemPage.TELEFONO -> Settings.ACTION_DEVICE_INFO_SETTINGS
            dev.vivac.launcher.core.SystemPage.TODO -> Settings.ACTION_SETTINGS
            dev.vivac.launcher.core.SystemPage.PERMISO_AJUSTES -> Settings.ACTION_MANAGE_WRITE_SETTINGS
        }
        val intent = Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (page == dev.vivac.launcher.core.SystemPage.PERMISO_AJUSTES) intent.data = Uri.fromParts("package", context.packageName, null)
        if (!start(intent)) start(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    override fun autoRotate(): Boolean =
        Settings.System.getInt(context.contentResolver, Settings.System.ACCELEROMETER_ROTATION, 0) == 1

    /** Needs "change system settings", which you grant vivac in Android's settings. */
    override fun setAutoRotate(on: Boolean): Boolean {
        if (!Settings.System.canWrite(context)) return false
        return Settings.System.putInt(context.contentResolver, Settings.System.ACCELEROMETER_ROTATION, if (on) 1 else 0)
    }

    override fun notificationSettings(packageName: String) {
        start(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /** The torch of the first camera with a flash; no permission needed, but the camera must be free. */
    override fun torch(on: Boolean): Boolean = runCatching {
        val cameras = context.getSystemService(android.hardware.camera2.CameraManager::class.java) ?: return false
        val id = cameras.cameraIdList.firstOrNull {
            cameras.getCameraCharacteristics(it).get(android.hardware.camera2.CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        } ?: return false
        cameras.setTorchMode(id, on)
        true
    }.getOrDefault(false)

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

    override fun backUp() {
        val name = "vivac-campamento-" + java.time.LocalDate.now() + ".txt"
        forResult(Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("text/plain").putExtra(Intent.EXTRA_TITLE, name), REQ_BACKUP)
    }

    override fun iconPacks(): List<dev.vivac.launcher.core.IconPackInfo> = AppIcons.packs(context)

    override fun pickWallpaper() {
        start(Intent.createChooser(Intent(Intent.ACTION_SET_WALLPAPER), "Fondo de pantalla").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    override fun pickBackup() {
        forResult(Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("text/plain"), REQ_RESTORE)
    }

    /** Screens that answer back (files, roles) need vivac's activity; there is always one when you tap these. */
    private fun forResult(intent: Intent, code: Int) {
        @Suppress("DEPRECATION")
        (context as? android.app.Activity)?.startActivityForResult(intent, code)
    }

    override fun isHome(): Boolean =
        context.getSystemService(android.app.role.RoleManager::class.java).isRoleHeld(android.app.role.RoleManager.ROLE_HOME)

    /** The role dialog needs an activity to answer to; from elsewhere, Android's default-apps page does the same. */
    override fun askToBeHome() {
        val roles = context.getSystemService(android.app.role.RoleManager::class.java)
        val activity = context as? android.app.Activity
        if (activity != null && roles.isRoleAvailable(android.app.role.RoleManager.ROLE_HOME)) {
            forResult(roles.createRequestRoleIntent(android.app.role.RoleManager.ROLE_HOME), REQ_HOME)
        } else {
            start(Intent(Settings.ACTION_HOME_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

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
