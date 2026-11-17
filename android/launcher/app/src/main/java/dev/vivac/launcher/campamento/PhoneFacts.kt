package dev.vivac.launcher.campamento

import android.content.Context
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

/** What the Campamento can say about this phone without asking anyone: all read locally. */
data class PhoneFacts(
    val build: String,
    val securityPatch: String,
    val freeGb: Long,
    val totalGb: Long,
    val batteryPercent: Int,
    val charging: Boolean,
) {
    companion object {
        private val spanish = Locale.forLanguageTag("es-ES")

        fun read(context: Context): PhoneFacts {
            val stat = StatFs(Environment.getDataDirectory().path)
            val battery = context.getSystemService(BatteryManager::class.java)
            return PhoneFacts(
                // GrapheneOS puts its release number (e.g. 2026103100) in INCREMENTAL.
                build = Build.VERSION.INCREMENTAL,
                securityPatch = patchLabel(Build.VERSION.SECURITY_PATCH),
                freeGb = stat.availableBytes / 1_000_000_000,
                totalGb = stat.totalBytes / 1_000_000_000,
                batteryPercent = battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY),
                charging = battery.isCharging,
            )
        }

        /** `2026-11-05` → `5 nov 2026`. */
        fun patchLabel(iso: String): String = runCatching {
            LocalDate.parse(iso).format(DateTimeFormatter.ofPattern("d MMM yyyy", spanish)).replace(".", "")
        }.getOrDefault(iso)
    }
}
