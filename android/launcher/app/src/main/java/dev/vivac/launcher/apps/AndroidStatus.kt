package dev.vivac.launcher.apps

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.telephony.SignalStrength
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import dev.vivac.launcher.campamento.PhoneStatus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * Adapter: the phone's mobile signal, Wi-Fi and Tailscale, followed while vivac is in front. It needs only to see
 * the network state (granted by Android on its own); no location, no phone permission.
 */
class AndroidStatus(private val context: Context) {
    private val current = MutableStateFlow(PhoneStatus())
    val live: StateFlow<PhoneStatus> = current.asStateFlow()

    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val telephony = context.getSystemService(TelephonyManager::class.java)
    private val wifiManager = context.getSystemService(WifiManager::class.java)

    internal val wifi = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            val level = wifiManager?.calculateSignalLevel(caps.signalStrength) ?: 0
            current.update { it.copy(wifi = PhoneStatus.bars(level, wifiManager?.maxSignalLevel ?: 4)) }
        }
        override fun onLost(network: Network) = current.update { it.copy(wifi = null) }
    }

    /** Every VPN up, and whether it is Tailscale's. */
    private val vpns = mutableMapOf<Network, Boolean>()

    internal val vpn = object : ConnectivityManager.NetworkCallback() {
        override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) {
            vpns[network] = PhoneStatus.isTailscale(lp.linkAddresses.mapNotNull { it.address.hostAddress })
            current.update { it.copy(tailscale = vpns.values.any { t -> t }) }
        }
        override fun onLost(network: Network) {
            vpns.remove(network)
            current.update { it.copy(tailscale = vpns.values.any { t -> t }) }
        }
    }

    internal val cell = Cell()

    /** The mobile signal, in Android's own four bars; none without a working SIM. */
    internal inner class Cell : TelephonyCallback(), TelephonyCallback.SignalStrengthsListener {
        override fun onSignalStrengthsChanged(strength: SignalStrength) {
            val ready = telephony?.simState == TelephonyManager.SIM_STATE_READY
            current.update { it.copy(cell = if (ready) strength.level.coerceIn(0, 4) else null) }
        }
    }

    fun start() {
        runCatching { connectivity?.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), wifi) }
        runCatching {
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_VPN)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            connectivity?.registerNetworkCallback(request, vpn)
        }
        runCatching { telephony?.registerTelephonyCallback(context.mainExecutor, cell) }
    }

    fun stop() {
        runCatching { connectivity?.unregisterNetworkCallback(wifi) }
        runCatching { connectivity?.unregisterNetworkCallback(vpn) }
        runCatching { telephony?.unregisterTelephonyCallback(cell) }
    }
}
