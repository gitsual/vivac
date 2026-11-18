/*
 * Copyright (C) 2026 vivac
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.android.systemui.statusbar.phone

import android.app.KeyguardManager
import android.app.WindowConfiguration.ACTIVITY_TYPE_HOME
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.UserHandle
import android.util.Log
import android.view.MotionEvent
import android.view.ViewConfiguration
import com.android.systemui.shared.system.ActivityManagerWrapper
import kotlin.math.abs

/**
 * vivac: a swipe down on the status bar while the vivac launcher is the home screen in front opens
 * the launcher's own shade instead of Android's.
 *
 * Fed with every status bar touch by [PhoneStatusBarViewController] (legacy touch path only, i.e.
 * scene container off). It never touches the shade itself: it only decides whether the gesture is
 * a plain one-finger swipe down over the vivac home, starts the launcher's entry activity, and
 * tells the caller to swallow the rest of the gesture. Any other case returns [Action.PASS] and
 * Android's shade behaves exactly as before.
 */
class VivacShadeRedirect(
    private val context: Context,
    /** Cheap, binder-free gate: shade collapsed, single-shade mode, panels enabled. */
    private val shadeAllowsRedirect: () -> Boolean,
) {
    enum class Action {
        /** Not ours: let Android's shade handle the event. */
        PASS,
        /** The launcher's shade was just started: cancel Android's tracking and swallow this event. */
        REDIRECTED,
        /** Rest of a redirected gesture: swallow. */
        SWALLOW,
    }

    private enum class Phase {
        IDLE,
        ARMED,
        REDIRECTING,
    }

    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private var phase = Phase.IDLE
    private var downX = 0f
    private var downY = 0f

    fun onStatusBarTouch(event: MotionEvent): Action {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x
                downY = event.y
                // y < 1 is the top edge, which the status bar eats for the shade as well.
                phase =
                    if (event.y >= 1f && event.pointerCount == 1 && gateAtDown()) Phase.ARMED
                    else Phase.IDLE
                return Action.PASS
            }
            MotionEvent.ACTION_MOVE -> {
                if (phase == Phase.REDIRECTING) return Action.SWALLOW
                if (phase != Phase.ARMED) return Action.PASS
                if (event.pointerCount > 1) {
                    // Two fingers open quick settings.
                    phase = Phase.IDLE
                    return Action.PASS
                }
                val dx = event.x - downX
                val dy = event.y - downY
                if (dy > touchSlop && dy > abs(dx)) {
                    // Decide once per gesture; whatever the answer, never retry.
                    if (vivacHomeIsInFront() && startVivacShade()) {
                        phase = Phase.REDIRECTING
                        return Action.REDIRECTED
                    }
                    phase = Phase.IDLE
                } else if (dy < -touchSlop || abs(dx) > touchSlop) {
                    phase = Phase.IDLE
                }
                return Action.PASS
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                if (phase == Phase.REDIRECTING) return Action.SWALLOW
                phase = Phase.IDLE
                return Action.PASS
            }
            MotionEvent.ACTION_UP,
            MotionEvent.ACTION_CANCEL -> {
                val wasRedirecting = phase == Phase.REDIRECTING
                phase = Phase.IDLE
                return if (wasRedirecting) Action.SWALLOW else Action.PASS
            }
            else -> return if (phase == Phase.REDIRECTING) Action.SWALLOW else Action.PASS
        }
    }

    private fun gateAtDown(): Boolean {
        val keyguardManager = context.getSystemService(KeyguardManager::class.java)
        if (keyguardManager == null || keyguardManager.isKeyguardLocked) return false
        return shadeAllowsRedirect()
    }

    /** The task in front is the default home, and that home is the vivac launcher. */
    private fun vivacHomeIsInFront(): Boolean {
        return try {
            val task = ActivityManagerWrapper.getInstance().runningTask ?: return false
            if (task.configuration.windowConfiguration.activityType != ACTIVITY_TYPE_HOME) {
                return false
            }
            if (task.topActivity?.packageName != LAUNCHER_PACKAGE) return false
            val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            val defaultHome = context.packageManager.resolveActivity(home, 0)
            defaultHome?.activityInfo?.packageName == LAUNCHER_PACKAGE
        } catch (e: Exception) {
            Log.w(TAG, "Could not tell what is in front; keeping Android's shade", e)
            false
        }
    }

    private fun startVivacShade(): Boolean {
        val intent =
            Intent(ACTION_OPEN_AVISOS)
                .setComponent(ComponentName(LAUNCHER_PACKAGE, AVISOS_ENTRY))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return try {
            context.startActivityAsUser(intent, UserHandle.CURRENT)
            true
        } catch (e: Exception) {
            Log.w(TAG, "vivac shade did not start; keeping Android's shade", e)
            false
        }
    }

    private companion object {
        const val TAG = "VivacShadeRedirect"
        const val LAUNCHER_PACKAGE = "dev.vivac.launcher"
        const val AVISOS_ENTRY = "dev.vivac.launcher.AvisosEntry"
        const val ACTION_OPEN_AVISOS = "dev.vivac.launcher.action.OPEN_AVISOS"
    }
}
