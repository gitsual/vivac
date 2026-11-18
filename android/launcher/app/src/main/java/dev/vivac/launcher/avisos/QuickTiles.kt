package dev.vivac.launcher.avisos

/**
 * The phone's controls a quick switch in vivac's shade can be. [id] is the name Android's own quick settings use,
 * so the default follows the phone's.
 */
enum class Control(val id: String, val title: String) {
    WIFI("wifi", "Wi-Fi"),
    BLUETOOTH("bt", "Bluetooth"),
    DATOS("cell", "Datos móviles"),
    AVION("airplane", "Modo avión"),
    NO_MOLESTAR("dnd", "No molestar"),
    LINTERNA("flashlight", "Linterna"),
    ROTACION("rotation", "Girar"),
    ALARMA("alarm", "Alarma"),
    GRABAR("screenrecord", "Grabar pantalla"),
    AHORRO("battery", "Ahorro de batería"),
    MICRO("mictoggle", "Micrófono"),
    CAMARA("cameratoggle", "Cámara"),
    UBICACION("location", "Ubicación"),
    ENVIAR("cast", "Enviar pantalla"),
    COMPARTIR("hotspot", "Compartir internet"),
    VOLUMEN("volume", "Volumen"),
    AJUSTES("settings", "Ajustes"),
    ANDROID("android", "Cortina de Android"),
    NFC("nfc", "NFC"),
    TEMA("dark", "Tema oscuro"),
    LUZ("night", "Luz nocturna"),
}

/** A quick switch in the shade: one of the phone's controls, or an app. */
sealed interface Quick {
    data class Of(val control: Control) : Quick
    data class App(val packageName: String) : Quick
}

/** The shade's quick switches: which, in what order, and how they are kept. */
object QuickTiles {
    /** The phone's own quick settings as they came, then Tailscale's, then vivac's volume, settings and Android's shade. */
    val DEFAULT: List<Quick> = listOf(
        Control.WIFI, Control.BLUETOOTH, Control.DATOS, Control.AVION, Control.NO_MOLESTAR, Control.LINTERNA, Control.ROTACION,
        Control.ALARMA, Control.GRABAR, Control.AHORRO, Control.MICRO, Control.CAMARA, Control.UBICACION, Control.ENVIAR, Control.COMPARTIR,
    ).map { Quick.Of(it) } + Quick.App("com.tailscale.ipn") + listOf(Control.VOLUMEN, Control.AJUSTES, Control.ANDROID).map { Quick.Of(it) }

    fun add(list: List<Quick>, quick: Quick): List<Quick> = if (quick in list) list else list + quick

    fun remove(list: List<Quick>, quick: Quick): List<Quick> = list - quick

    /** One place earlier (-1) or later (+1), stopping at the ends. */
    fun move(list: List<Quick>, quick: Quick, delta: Int): List<Quick> {
        val at = list.indexOf(quick).takeIf { it >= 0 } ?: return list
        val to = (at + delta).coerceIn(0, list.lastIndex)
        return list.toMutableList().apply { removeAt(at); add(to, quick) }
    }

    /**
     * The order a two-row grid that fills column by column needs, for each page of eight to read row by row as
     * Android's quick settings do: four across, then four more below. A short last page is padded with nulls (empty
     * places) so its tiles stay in the top row.
     */
    fun columns(list: List<Quick>): List<Quick?> = list.chunked(8).flatMap { page ->
        (0 until minOf(page.size, 4)).flatMap { c -> listOf(page[c], page.getOrNull(c + 4)) }
    }

    /** Every control not in the shade yet, to add. */
    fun available(list: List<Quick>): List<Control> = Control.entries.filter { Quick.Of(it) !in list }

    fun encode(list: List<Quick>): String = list.joinToString(",") {
        when (it) {
            is Quick.Of -> it.control.id
            is Quick.App -> "app:${it.packageName}"
        }
    }

    /** Reads what [encode] wrote; nothing kept yet is the default, and ids it does not know are dropped. */
    fun decode(raw: String?): List<Quick> {
        if (raw == null) return DEFAULT
        val byId = Control.entries.associateBy { it.id }
        return raw.split(",").mapNotNull { id ->
            when {
                id.startsWith("app:") -> id.removePrefix("app:").takeIf { it.isNotBlank() }?.let { Quick.App(it) }
                else -> byId[id]?.let { Quick.Of(it) }
            }
        }.distinct()
    }
}
