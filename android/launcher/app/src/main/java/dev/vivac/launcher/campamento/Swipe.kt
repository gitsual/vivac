package dev.vivac.launcher.campamento

/** Vertical swipes on the Campamento: down shows notifications, up opens the Petate. */
enum class Swipe {
    DOWN,
    UP,
    NONE;

    companion object {
        /** Travel that counts on its own, about the height of one tile. */
        private const val DISTANCE_DP = 48f

        /** A flick this fast counts even when short. */
        private const val VELOCITY_DP = 600f

        fun classify(dyDp: Float, velocityDp: Float): Swipe {
            val far = kotlin.math.abs(dyDp) >= DISTANCE_DP
            // A fast flick only counts when it goes the same way as the drag (and the drag moved at all).
            val flick = kotlin.math.abs(velocityDp) >= VELOCITY_DP && dyDp != 0f && (dyDp > 0) == (velocityDp > 0)
            return when {
                !far && !flick -> NONE
                dyDp > 0 -> DOWN
                else -> UP
            }
        }
    }
}
