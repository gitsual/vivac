package dev.vivac.launcher.campamento

/**
 * A widget vivac draws itself, in its own type, glyphs and sizes, from what an app already shares: its
 * notifications (chats) or its shortcuts. On the board it is a [Placed] with a negative id, so it is carried,
 * resized and removed like any other widget.
 */
sealed interface VivacWidget {
    val packageName: String
    /** How many rows it takes when placed. */
    val rows: Int
    val key: String

    /** The latest conversations of a chat app, from its notifications. */
    data class Chats(override val packageName: String) : VivacWidget {
        override val rows = 3
        override val key = "$PREFIX$CHATS:$packageName"
    }

    /** An app's shortcuts (Claude's "Pregunta a Claude", voice, camera...) as vivac buttons. */
    data class Atajos(override val packageName: String) : VivacWidget {
        override val rows = 1
        override val key = "$PREFIX$ATAJOS:$packageName"
    }

    /** At a glance: the next alarm, the next event and what is playing. vivac's own, so its "package" is vivac. */
    data object Glance : VivacWidget {
        override val packageName = "dev.vivac.launcher"
        override val rows = 2
        override val key = "$PREFIX$GLANCE:$packageName"
    }

    companion object {
        private const val GLANCE = "glance"
        private const val PREFIX = "vivac:"
        private const val CHATS = "chats"
        private const val ATAJOS = "atajos"

        /** The widget a picker key names, or null for an app's own widget. */
        fun fromKey(key: String): VivacWidget? {
            if (!key.startsWith(PREFIX)) return null
            val kind = key.removePrefix(PREFIX).substringBefore(":")
            val pkg = key.removePrefix(PREFIX).substringAfter(":", "").takeIf { it.isNotBlank() } ?: return null
            return when (kind) {
                CHATS -> Chats(pkg)
                ATAJOS -> Atajos(pkg)
                GLANCE -> Glance
                else -> null
            }
        }

        fun encode(placed: Map<Int, VivacWidget>): String = placed.entries.joinToString(",") { "${it.key}=${it.value.key}" }

        fun decode(raw: String?): Map<Int, VivacWidget> = raw.orEmpty().split(",").mapNotNull { entry ->
            val id = entry.substringBefore("=").toIntOrNull() ?: return@mapNotNull null
            val widget = fromKey(entry.substringAfter("=", "")) ?: return@mapNotNull null
            id to widget
        }.toMap()
    }
}

/** The line glyph a shortcut gets from what its label says. */
enum class ShortcutGlyph(val path: String) {
    VOICE("M4 12h2 M8 8v8 M12 5v14 M16 8v8 M20 12h-2"),
    CAMERA("M3 8h4l2-3h6l2 3h4v11H3z M12 10a3.5 3.5 0 1 0 0 7a3.5 3.5 0 1 0 0-7z"),
    MIC("M9 5a3 3 0 0 1 6 0v6a3 3 0 0 1-6 0z M5 11a7 7 0 0 0 14 0 M12 18v3"),
    CODE("M8 7l-5 5 5 5 M16 7l5 5-5 5 M14 4l-4 16"),
    ASK("M4 5h16v11H9l-5 4z M8 9h8 M8 12h5"),
    ARROW("M5 12h14M13 6l6 6-6 6"),
    ;

    companion object {
        fun of(label: String): ShortcutGlyph {
            val l = label.lowercase()
            return when {
                "voz" in l || "voice" in l -> VOICE
                "cámara" in l || "camara" in l || "camera" in l || "foto" in l -> CAMERA
                "dictado" in l || "dictat" in l || "micr" in l -> MIC
                "code" in l || "código" in l -> CODE
                "pregunta" in l || "chat" in l || "ask" in l || "nuevo" in l || "new" in l -> ASK
                else -> ARROW
            }
        }
    }
}
