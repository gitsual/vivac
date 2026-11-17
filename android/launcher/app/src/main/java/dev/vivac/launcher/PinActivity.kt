package dev.vivac.launcher

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.content.pm.LauncherApps
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.vivac.launcher.apps.PrefsStore
import dev.vivac.launcher.core.PinDesk
import dev.vivac.launcher.core.PinOffer
import dev.vivac.launcher.core.WidgetStep
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.theme.Type
import dev.vivac.launcher.widgets.Widgets

/**
 * Where another app's "Add to home screen" lands: Android sends it only to the default home app.
 * vivac shows what is offered and where it will go; saying yes puts it on a ladera.
 */
class PinActivity : ComponentActivity() {
    private var desk: PinDesk? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val request = getSystemService(LauncherApps::class.java).getPinItemRequest(intent)
        val widgets = Widgets(this)
        val offer = request?.takeIf { it.isValid }?.let { r ->
            when (r.requestType) {
                LauncherApps.PinItemRequest.REQUEST_TYPE_SHORTCUT -> r.shortcutInfo?.let { PinOffer.Shortcut(it.`package`, it.id, (it.shortLabel ?: it.longLabel ?: "").toString()) }
                else -> r.getAppWidgetProviderInfo(this)?.let { PinOffer.Widget(widgets.optionOf(it)) }
            }
        }
        if (request == null || offer == null) return finish()
        val desk = PinDesk(
            PrefsStore(getSharedPreferences("home", MODE_PRIVATE)),
            widgets,
            accept = { id ->
                request.isValid && if (id == -1) request.accept() else request.accept(Bundle().apply { putInt(AppWidgetManager.EXTRA_APPWIDGET_ID, id) })
            },
            pendingWidget = savedInstanceState?.getInt(KEY_PENDING, -1) ?: -1,
        ).also { desk = it }
        setContent {
            LaunchedEffect(desk.done) { if (desk.done) finish() }
            PinSheet(offer.label, desk.ladera, onAdd = { desk.add(offer) }, onDecline = desk::decline)
        }
    }

    @Deprecated("The widget host API still answers through onActivityResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION") super.onActivityResult(requestCode, resultCode, data)
        val step = when (requestCode) {
            Widgets.REQ_BIND -> WidgetStep.BIND
            Widgets.REQ_CONFIGURE -> WidgetStep.CONFIGURE
            else -> return
        }
        desk?.onWidgetResult(step, resultCode == RESULT_OK)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putInt(KEY_PENDING, desk?.pendingWidget ?: -1)
    }

    private companion object {
        const val KEY_PENDING = "pendingWidget"
    }
}

/** The offer, over a dimmed screen: what it is, which ladera it goes to, add or not now. */
@Composable
private fun PinSheet(label: String, ladera: Int, onAdd: () -> Unit, onDecline: () -> Unit) {
    Box(
        Modifier
            .fillMaxSize()
            .background(Ink.deep.copy(alpha = 0.6f))
            .clickable(onClickLabel = "Ahora no", onClick = onDecline),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Column(
            Modifier
                .windowInsetsPadding(WindowInsets.navigationBars)
                .padding(16.dp)
                .fillMaxWidth()
                .clip(RoundedCornerShape(28.dp))
                .background(Ink.surface)
                .border(1.dp, Ink.field, RoundedCornerShape(28.dp))
                .clickable(enabled = false) {}
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("AÑADIR AL CAMPAMENTO", style = Type.cota.copy(fontSize = 10.sp))
            Text(label, style = Type.title.copy(fontSize = 28.sp, lineHeight = 30.sp), modifier = Modifier.semantics { heading() })
            Text("Irá a la ladera $ladera. Luego puedes llevarlo donde quieras.", style = Type.body.copy(color = Ink.textMuted))
            Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Pill("Ahora no", Ink.raised, Ink.text, Modifier.weight(1f), onDecline)
                Pill("Añadir", Ink.primary, Ink.deep, Modifier.weight(1f), onAdd)
            }
        }
    }
}

@Composable
private fun Pill(text: String, background: Color, color: Color, modifier: Modifier, onClick: () -> Unit) {
    Box(
        modifier
            .height(52.dp)
            .clip(RoundedCornerShape(26.dp))
            .background(background)
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Text(text, style = Type.body.copy(color = color)) }
}
