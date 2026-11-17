package dev.vivac.launcher.widgets

import android.app.Activity
import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetHostView
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProviderInfo
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.util.SizeF
import dev.vivac.launcher.campamento.WidgetSize
import dev.vivac.launcher.core.WidgetHost
import java.text.Collator
import java.util.Locale

/** A widget an installed app offers, as the picker lists it. */
data class WidgetOption(
    /** The provider's flattened component name. */
    val key: String,
    val label: String,
    val appLabel: String,
    val appPackage: String,
    val cells: String,
)

/** Adapter over Android's app-widget host: what can be added, binding, configuring and drawing. */
class Widgets(private val activity: Activity) : WidgetHost {
    private val manager = AppWidgetManager.getInstance(activity)
    private val host = AppWidgetHost(activity, HOST_ID)
    private val density = activity.resources.displayMetrics.density

    fun startListening() = host.startListening()
    fun stopListening() = host.stopListening()

    override fun options(): List<WidgetOption> {
        val pm = activity.packageManager
        val collator = Collator.getInstance(Locale.forLanguageTag("es-ES"))
        return manager.getInstalledProvidersForProfile(Process.myUserHandle()).map { info ->
            val pkg = info.provider.packageName
            WidgetOption(
                key = info.provider.flattenToString(),
                label = info.loadLabel(pm).toString(),
                appLabel = runCatching { pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString() }.getOrDefault(pkg),
                appPackage = pkg,
                cells = WidgetSize.cells(targetColumns(info), targetRows(info)),
            )
        }.sortedWith(compareBy(collator) { it.appLabel + " " + it.label })
    }

    override fun allocate(): Int = host.allocateAppWidgetId()

    override fun bindIfAllowed(id: Int, option: WidgetOption): Boolean =
        manager.bindAppWidgetIdIfAllowed(id, Process.myUserHandle(), ComponentName.unflattenFromString(option.key), null)

    /** The system dialog that asks you to allow vivac to place this widget. */
    fun bindRequest(id: Int, option: WidgetOption): Intent =
        Intent(AppWidgetManager.ACTION_APPWIDGET_BIND)
            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_PROVIDER, ComponentName.unflattenFromString(option.key))
            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_PROVIDER_PROFILE, Process.myUserHandle())

    @Suppress("DEPRECATION")
    override fun requestBind(id: Int, option: WidgetOption) = activity.startActivityForResult(bindRequest(id, option), REQ_BIND)

    override fun needsConfiguring(id: Int): Boolean = manager.getAppWidgetInfo(id)?.configure != null

    override fun requestConfigure(id: Int) =
        host.startAppWidgetConfigureActivityForResult(activity, id, 0, REQ_CONFIGURE, null)

    override fun delete(id: Int) = host.deleteAppWidgetId(id)

    override fun exists(id: Int): Boolean = manager.getAppWidgetInfo(id) != null

    override fun label(id: Int): String = manager.getAppWidgetInfo(id)?.loadLabel(activity.packageManager)?.toString() ?: "widget"

    fun heightDp(id: Int): Int {
        val info = manager.getAppWidgetInfo(id) ?: return WidgetSize.MIN_DP
        return WidgetSize.heightDp((info.minHeight / density).toInt(), targetRows(info))
    }

    /** The live view of a placed widget, told the size it is drawn at so responsive widgets lay out right. */
    fun view(context: Context, id: Int, widthDp: Float): AppWidgetHostView? {
        val info = manager.getAppWidgetInfo(id) ?: return null
        val view = host.createView(context, id, info)
        val heightDp = heightDp(id).toFloat()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            view.updateAppWidgetSize(Bundle(), listOf(SizeF(widthDp, heightDp)))
        }
        return view
    }

    private fun targetColumns(info: AppWidgetProviderInfo) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) info.targetCellWidth else 0
    private fun targetRows(info: AppWidgetProviderInfo) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) info.targetCellHeight else 0

    companion object {
        /** Any fixed number; it names vivac's widget host to the system. */
        private const val HOST_ID = 0x7661
        const val REQ_BIND = 7001
        const val REQ_CONFIGURE = 7002
    }
}
