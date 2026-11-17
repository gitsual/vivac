package dev.vivac.launcher.apps

import android.content.SharedPreferences
import dev.vivac.launcher.core.Store

/** Adapter: the layout lives in a private SharedPreferences file. */
class PrefsStore(private val prefs: SharedPreferences) : Store {
    override fun get(key: String): String? = prefs.getString(key, null)

    override fun put(changes: Map<String, String>) {
        val edit = prefs.edit()
        changes.forEach { (k, v) -> edit.putString(k, v) }
        edit.apply()
    }
}
