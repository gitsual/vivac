package dev.vivac.launcher.apps

import android.app.admin.DeviceAdminReceiver

/**
 * The other way to turn the screen off: a device admin that asks for one policy only, force-lock. Android then
 * wants the PIN on the next unlock instead of the fingerprint, which is why accessibility stays the default.
 */
class LockAdmin : DeviceAdminReceiver()
