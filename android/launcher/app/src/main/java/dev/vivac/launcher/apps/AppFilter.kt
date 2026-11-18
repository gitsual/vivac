package dev.vivac.launcher.apps

import android.util.Xml
import org.xmlpull.v1.XmlPullParser
import java.io.InputStream

/**
 * An icon pack's appfilter.xml, the ADW/Nova convention every pack follows:
 * `<item component="ComponentInfo{package/activity}" drawable="name"/>`, one per launcher activity.
 */
object AppFilter {
    private val COMPONENT = Regex("""^ComponentInfo\{([^/}]+/[^}]+)\}$""")

    /** "package/activity" to the pack's drawable name; an unreadable file is an empty pack. */
    fun parse(input: InputStream): Map<String, String> = runCatching { read(Xml.newPullParser().apply { setInput(input, null) }) }.getOrDefault(emptyMap())

    fun read(parser: XmlPullParser): Map<String, String> {
        val map = mutableMapOf<String, String>()
        while (parser.next() != XmlPullParser.END_DOCUMENT) {
            if (parser.eventType != XmlPullParser.START_TAG || parser.name != "item") continue
            val component = parser.getAttributeValue(null, "component")?.let { COMPONENT.find(it)?.groupValues?.get(1) } ?: continue
            val drawable = parser.getAttributeValue(null, "drawable") ?: continue
            map.putIfAbsent(component, drawable)
        }
        return map
    }
}
