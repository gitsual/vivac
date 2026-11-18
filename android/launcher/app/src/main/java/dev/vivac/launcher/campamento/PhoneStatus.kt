package dev.vivac.launcher.campamento

/**
 * The phone's connections, as the camp shows them top left: mobile signal and Wi-Fi in bars of four (null when there
 * is none), and whether Tailscale is up.
 */
data class PhoneStatus(val cell: Int? = null, val wifi: Int? = null, val tailscale: Boolean = false) {
    /** What TalkBack reads. */
    val spoken: String
        get() = listOfNotNull(
            cell?.let { "Cobertura $it de 4" } ?: "Sin cobertura",
            wifi?.let { "Wi-Fi $it de 4" } ?: "sin Wi-Fi",
            "Tailscale conectado".takeIf { tailscale },
        ).joinToString(", ")

    companion object {
        /** Tailscale gives each device an address in 100.64.0.0/10, the shared address space no one else hands out. */
        fun isTailscale(addresses: List<String>): Boolean = addresses.any { a ->
            val parts = a.split(".").mapNotNull { it.toIntOrNull() }
            parts.size == 4 && parts[0] == 100 && parts[1] in 64..127
        }

        /** A signal [level] out of [max] as bars out of four. */
        fun bars(level: Int, max: Int): Int = if (max <= 0) 0 else Math.round(level.coerceIn(0, max) * 4f / max)
    }
}
