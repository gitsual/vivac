package dev.vivac.launcher.core

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dev.vivac.launcher.campamento.WidgetBoard
import dev.vivac.launcher.widgets.WidgetOption

/** Something another app asks to put on the home screen ("Add to home screen"). */
sealed interface PinOffer {
    val label: String

    data class Shortcut(val packageName: String, val id: String, override val label: String) : PinOffer

    data class Widget(val option: WidgetOption) : PinOffer {
        override val label get() = option.label
    }
}

/**
 * Answers an app's request to add something to the home screen, while vivac's own screen is not in front.
 * It writes straight to the layout in [store]; the camp reads it back when you return to it.
 * [accept] is Android's request: it says yes with the widget id (-1 for a shortcut), and false if the request is gone.
 */
class PinDesk(
    private val store: Store,
    private val widgets: WidgetHost,
    private val accept: (widgetId: Int) -> Boolean,
    pendingWidget: Int = -1,
) {
    /** The request is answered; the screen can close. */
    var done by mutableStateOf(false); private set
    var pendingWidget = pendingWidget; private set

    /** The ladera the offer will go to. */
    val ladera: Int get() = board().lastLadera

    fun add(offer: PinOffer) {
        when (offer) {
            is PinOffer.Shortcut -> {
                if (accept(-1)) save(board().addShortcut(offer.packageName, offer.id, offer.label, ladera))
                done = true
            }
            is PinOffer.Widget -> {
                val id = widgets.allocate()
                pendingWidget = id
                if (widgets.bindIfAllowed(id, offer.option)) afterBind(id) else widgets.requestBind(id, offer.option)
            }
        }
    }

    fun decline() {
        done = true
    }

    fun onWidgetResult(step: WidgetStep, ok: Boolean) {
        val id = pendingWidget
        if (id == -1) return
        when {
            !ok -> drop(id)
            step == WidgetStep.BIND -> afterBind(id)
            else -> place(id)
        }
    }

    private fun afterBind(id: Int) = when {
        !accept(id) -> drop(id)
        widgets.needsConfiguring(id) -> widgets.requestConfigure(id)
        else -> place(id)
    }

    private fun place(id: Int) {
        pendingWidget = -1
        save(board().addOnLadera(id))
        done = true
    }

    private fun drop(id: Int) {
        pendingWidget = -1
        widgets.delete(id)
        done = true
    }

    private fun board() = WidgetBoard.decode(store.get(Launcher.KEY_WIDGETS))

    private fun save(next: WidgetBoard) = store.put(mapOf(Launcher.KEY_WIDGETS to next.encode()))
}
