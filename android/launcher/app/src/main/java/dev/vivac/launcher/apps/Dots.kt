package dev.vivac.launcher.apps

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Packages with a dot, provided once by the activity. */
val LocalDots = androidx.compose.runtime.compositionLocalOf { emptySet<String>() }

/** How many notifications each app has; tiles show the number only when you chose counts over dots. */
val LocalCounts = androidx.compose.runtime.compositionLocalOf { emptyMap<String, Int>() }

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

    /** How many of those notifications each app has. */
    fun counts(notices: List<Notice>): Map<String, Int> =
        notices.filter { !it.ongoing && it.canShowBadge && !it.isGroupSummary }.groupingBy { it.packageName }.eachCount()

    private val current = MutableStateFlow(emptySet<String>())
    private val currentCounts = MutableStateFlow(emptyMap<String, Int>())

    val liveCounts: StateFlow<Map<String, Int>> = currentCounts.asStateFlow()

    /** Live set fed by [DotsListener]; empty while notification access is off. */
    val live: StateFlow<Set<String>> = current.asStateFlow()

    internal fun publish(dots: Set<String>, counts: Map<String, Int> = emptyMap()) {
        current.value = dots
        currentCounts.value = counts
    }
}
