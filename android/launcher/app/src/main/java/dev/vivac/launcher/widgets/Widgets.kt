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
    private val host = object : AppWidgetHost(activity, HOST_ID) {
        override fun onCreateView(context: Context, appWidgetId: Int, appWidget: AppWidgetProviderInfo?): AppWidgetHostView = WidgetFrame(context)
    }
    private val density = activity.resources.displayMetrics.density

    fun startListening() = host.startListening()
    fun stopListening() = host.stopListening()

    override fun options(): List<WidgetOption> {
        val collator = Collator.getInstance(Locale.forLanguageTag("es-ES"))
        return manager.getInstalledProvidersForProfile(Process.myUserHandle()).map(::optionOf)
            .sortedWith(compareBy(collator) { it.appLabel + " " + it.label })
    }

    /** How a provider reads in the picker, or in an app's "add to home screen" request. */
    fun optionOf(info: AppWidgetProviderInfo): WidgetOption {
        val pm = activity.packageManager
        val pkg = info.provider.packageName
        return WidgetOption(
            key = info.provider.flattenToString(),
            label = info.loadLabel(pm).toString(),
            appLabel = runCatching { pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString() }.getOrDefault(pkg),
            appPackage = pkg,
            cells = WidgetSize.cells(targetColumns(info), targetRows(info)),
        )
    }

    override fun allocate(): Int = host.allocateAppWidgetId()

    override fun bindIfAllowed(id: Int, option: WidgetOption): Boolean =
        manager.bindAppWidgetIdIfAllowed(id, ComponentName.unflattenFromString(option.key))

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

    override fun defaultRows(id: Int): Int = WidgetSize.rowsOf(heightDp(id))

    /** Drawn height: the rows you chose ([rows] > 0), else the widget's own. */
    fun heightDp(id: Int, rows: Int = 0): Int {
        val info = manager.getAppWidgetInfo(id) ?: return WidgetSize.MIN_DP
        return WidgetSize.heightDp((info.minHeight / density).toInt(), targetRows(info), rows)
    }

    /** The live view of a placed widget at the size it is drawn, so responsive widgets lay out right; a held finger goes to [grip]. */
    fun view(context: Context, id: Int, widthDp: Float, rows: Int, grip: Grip): AppWidgetHostView? {
        val info = manager.getAppWidgetInfo(id) ?: return null
        // Drawn at night, as all of vivac is: a widget with a dark look uses it.
        // A wrapper around the activity, not a new context, so the widget's buttons still start apps from it.
        val night = android.view.ContextThemeWrapper(context, context.theme).apply {
            applyOverrideConfiguration(
                android.content.res.Configuration(context.resources.configuration).apply {
                    uiMode = (uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK.inv()) or android.content.res.Configuration.UI_MODE_NIGHT_YES
                },
            )
        }
        val view = host.createView(night, id, info)
        // A widget drawn with the system's colours takes vivac's palette instead of the wallpaper's.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) view.setColorResources(WidgetColors.resources())
        (view as? WidgetFrame)?.grip = grip
        val heightDp = heightDp(id, rows).toFloat()
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
