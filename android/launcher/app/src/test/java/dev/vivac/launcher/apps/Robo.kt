package dev.vivac.launcher.apps

import android.content.Context
import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import android.content.pm.LauncherActivityInfo
import android.os.Process
import android.os.UserHandle
import org.robolectric.util.ReflectionHelpers
import org.robolectric.util.ReflectionHelpers.ClassParameter

/** Test helpers for Android types whose constructors are hidden. */
object Robo {
    fun activity(context: Context, label: String, pkg: String, system: Boolean = false, user: UserHandle = Process.myUserHandle()): LauncherActivityInfo {
        val info = ActivityInfo().apply {
            packageName = pkg
            name = "$pkg.Main"
            nonLocalizedLabel = label
            applicationInfo = ApplicationInfo().apply {
                packageName = pkg
                flags = if (system) ApplicationInfo.FLAG_SYSTEM else 0
            }
        }
        val internalClass = Class.forName("android.content.pm.LauncherActivityInfoInternal")
        val internal = ReflectionHelpers.callConstructor(
            internalClass,
            ClassParameter.from(ActivityInfo::class.java, info),
            ClassParameter.from(Class.forName("android.content.pm.IncrementalStatesInfo"), null),
            ClassParameter.from(UserHandle::class.java, user),
        )
        return ReflectionHelpers.callConstructor(
            LauncherActivityInfo::class.java,
            ClassParameter.from(Context::class.java, context),
            ClassParameter(internalClass, internal),
        )
    }
}
