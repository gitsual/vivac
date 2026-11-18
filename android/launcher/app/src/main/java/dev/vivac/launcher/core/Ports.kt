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
    /** One of Android's settings pages, or one of its small panels (internet, volume). */
    fun systemPage(page: SystemPage)
    /** Switches the torch; false when the phone will not (no flash, or the camera is in use). */
    fun torch(on: Boolean): Boolean
    /** Whether the screen turns with the phone. */
    fun autoRotate(): Boolean
    /** Turns auto-rotation on or off; false when you have not let vivac change system settings. */
    fun setAutoRotate(on: Boolean): Boolean
    /** Android's page for one app's notifications. */
    fun notificationSettings(packageName: String)
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
    /** Android's wallpaper picker. */
    fun pickWallpaper()
    /** Icon packs installed on the phone. */
    fun iconPacks(): List<IconPackInfo>
    /** Android's file picker for a copy to restore. */
    fun pickBackup()
    /** The web search app you use (or the browser), for [query]. */
    fun webSearch(query: String)
    /** The app store you use (any that answers market:// links), for [query]. */
    fun storeSearch(query: String)
}

/** Port: the phone's notifications, for vivac's own shade, and what you do with them. */
interface Notices {
    /** What is on the phone now; empty while notification access is off. */
    val live: kotlinx.coroutines.flow.StateFlow<List<dev.vivac.launcher.avisos.Aviso>>
    /** Runs the notice's own action (opens the chat, the mail...). */
    fun open(key: String)
    fun dismiss(key: String)
    /** Clears every notice that can be cleared, as Android's "Clear all" does. */
    fun dismissAll()
    /** Answers a notice that takes a written reply; false when it could not. */
    fun reply(key: String, text: String): Boolean
    /** Whether Do Not Disturb is on. */
    fun quiet(): Boolean
    /** Turns Do Not Disturb on (priority only) or off; false without notification access. */
    fun setQuiet(on: Boolean): Boolean
}

/** Android's settings pages vivac's settings hub opens, with how the hub names them. */
enum class SystemPage(val title: String, val detail: String) {
    INTERNET("Internet", "Wi-Fi y datos móviles"),
    BLUETOOTH("Bluetooth", "Auriculares, reloj, coche"),
    PANTALLA("Pantalla", "Brillo, tema oscuro, tamaño del texto"),
    SONIDO("Sonido y vibración", "Volumen, no molestar, tonos"),
    BATERIA("Batería", "Uso y ahorro de batería"),
    NOTIFICACIONES("Notificaciones", "Qué apps te avisan y cómo"),
    APPS("Aplicaciones", "Permisos, apps por defecto"),
    ALMACENAMIENTO("Almacenamiento", "Qué ocupa espacio"),
    SEGURIDAD("Seguridad y privacidad", "Bloqueo, huella, permisos"),
    UBICACION("Ubicación", "Qué apps saben dónde estás"),
    SISTEMA("Idioma y región", "Idioma, formatos de fecha y números"),
    TELEFONO("Información del teléfono", "Modelo, versión, actualizaciones"),
    TODO("Todos los ajustes de Android", "La app de Ajustes, entera"),
    VOLUMEN("Volumen", "El panel de volumen de Android"),
    WIFI("Wi-Fi", "El panel de Wi-Fi de Android"),
    DATOS("Datos móviles", "La red móvil"),
    AVION("Modo avión", "Redes e internet"),
    ALARMAS("Alarmas", "Las alarmas del reloj"),
    AHORRO("Ahorro de batería", "Cuándo se activa"),
    PRIVACIDAD("Micrófono y cámara", "Los controles de privacidad"),
    ENVIAR("Enviar pantalla", "A una tele o un altavoz"),
    COMPARTIR("Compartir internet", "Punto de acceso y anclaje"),
    NFC("NFC", "El panel de NFC de Android"),
    TEMA("Tema oscuro", "Cuándo se oscurece el teléfono"),
    LUZ("Luz nocturna", "Menos azul por la noche"),
    PERMISO_AJUSTES("Cambiar ajustes del sistema", "El permiso que vivac necesita para girar la pantalla"),
    ;

    companion object {
        /** The hub's list, in order; the rest are pages the shade's switches open. */
        val hub: List<SystemPage> = listOf(INTERNET, BLUETOOTH, PANTALLA, SONIDO, BATERIA, NOTIFICACIONES, APPS, ALMACENAMIENTO, SEGURIDAD, UBICACION, SISTEMA, TELEFONO, TODO)
    }
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

/** A person from your contacts, as the Petate's search finds them. */
data class Contact(val id: Long, val name: String, val lookup: String)

/** An event from your calendars: when it starts (epoch millis) and its title. */
data class CalendarEvent(val id: Long, val title: String, val startMillis: Long)

/** Port: your contacts and calendars, read only when you allowed it (Android's own permissions). */
interface Directory {
    fun canReadContacts(): Boolean
    fun canReadCalendar(): Boolean
    fun contacts(query: String): List<Contact>
    /** Events whose title matches, from now on. */
    fun events(query: String): List<CalendarEvent>
    fun openContact(contact: Contact)
    fun openEvent(event: CalendarEvent)
    /** Android's permission dialog, for contacts or for calendars. */
    fun askContacts()
    fun askCalendar()
}

