package dev.vivac.launcher.apps

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Packages with a dot, provided once by the activity. */
val LocalDots = androidx.compose.runtime.compositionLocalOf { emptySet<String>() }

/** What vivac keeps from a notification: whose it is and how it behaves. Never its text. */
data class Notice(
    val packageName: String,
    val ongoing: Boolean,
    val canShowBadge: Boolean,
    val isGroupSummary: Boolean,
)

object Dots {
    /** Packages that deserve a dot: a non-ongoing notification on a channel that allows badges, summaries alone not counting. */
    fun of(notices: List<Notice>): Set<String> =
        notices.filter { !it.ongoing && it.canShowBadge && !it.isGroupSummary }.map { it.packageName }.toSet()

    private val current = MutableStateFlow(emptySet<String>())

    /** Live set fed by [DotsListener]; empty while notification access is off. */
    val live: StateFlow<Set<String>> = current.asStateFlow()

    internal fun publish(dots: Set<String>) {
        current.value = dots
    }
}
