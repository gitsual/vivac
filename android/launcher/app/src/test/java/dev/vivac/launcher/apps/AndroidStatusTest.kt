package dev.vivac.launcher.apps

import android.app.Application
import android.net.LinkAddress
import android.net.LinkProperties
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.shadows.ShadowNetwork
import org.robolectric.shadows.ShadowNetworkCapabilities

@RunWith(AndroidJUnit4::class)
class AndroidStatusTest {
    private val app = ApplicationProvider.getApplicationContext<Application>()

    @Test
    fun `it follows Wi-Fi, Tailscale and the mobile signal while started`() {
        val status = AndroidStatus(app)
        status.start()
        val net = ShadowNetwork.newInstance(7)
        status.wifi.onCapabilitiesChanged(net, ShadowNetworkCapabilities.newInstance())
        assertTrue(status.live.value.wifi != null)
        status.wifi.onLost(net)
        assertEquals(null, status.live.value.wifi)
        val tun = ShadowNetwork.newInstance(8)
        // LinkAddress(String) and addLinkAddress are hidden from apps; the test builds them as Android does.
        val address = org.robolectric.util.ReflectionHelpers.callConstructor(
            LinkAddress::class.java, org.robolectric.util.ReflectionHelpers.ClassParameter.from(String::class.java, "100.73.224.90/32"),
        )
        val props = LinkProperties()
        org.robolectric.util.ReflectionHelpers.callInstanceMethod<Any>(props, "addLinkAddress", org.robolectric.util.ReflectionHelpers.ClassParameter.from(LinkAddress::class.java, address))
        status.vpn.onLinkPropertiesChanged(tun, props)
        assertTrue(status.live.value.tailscale)
        status.vpn.onLost(tun)
        assertFalse(status.live.value.tailscale)
        status.cell.onSignalStrengthsChanged(org.robolectric.util.ReflectionHelpers.callConstructor(android.telephony.SignalStrength::class.java))
        status.stop()
    }
}
