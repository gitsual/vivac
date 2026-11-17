package dev.vivac.launcher.campamento

/** Vertical swipes on the Campamento: down shows notifications, up opens the Petate. */
enum class Swipe {
    DOWN,
    UP,
    NONE;

    companion object {
        /** Travel that counts on its own, about the height of one tile. */
        private const val DISTANCE_DP = 48f

        /** A flick this fast counts even when short... */
        private const val VELOCITY_DP = 600f

        /** ...but it must still travel this far: a tremor in a long press can measure as very fast. */
        private const val FLICK_MIN_DP = 12f

        fun classify(dyDp: Float, velocityDp: Float): Swipe {
            val far = kotlin.math.abs(dyDp) >= DISTANCE_DP
            // A fast flick only counts when it travelled a little and goes the same way as the drag.
            val flick = kotlin.math.abs(velocityDp) >= VELOCITY_DP &&
                kotlin.math.abs(dyDp) >= FLICK_MIN_DP &&
                (dyDp > 0) == (velocityDp > 0)
            return when {
                !far && !flick -> NONE
                dyDp > 0 -> DOWN
                else -> UP
            }
        }
    }
}
