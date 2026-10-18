package com.androidwebcam.app.transport

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log

/** Identity + metadata the advertiser publishes. Supplied lazily so the
 *  service can create the advertiser before cameras are enumerated. */
data class DiscoveryConfig(
    val id: String,
    val model: String,
    val brand: String,
    val sdk: Int,
    val port: Int = WamcDiscovery.PORT,
    val emulator: Boolean = AndroidDeviceIdentity.isEmulator(),
)

/** Classifies build identity for discovery; physical phones stay discoverable. */
private object AndroidDeviceIdentity {
    fun isEmulator(): Boolean {
        val fingerprint = Build.FINGERPRINT.orEmpty().lowercase()
        val model = Build.MODEL.orEmpty().lowercase()
        val product = Build.PRODUCT.orEmpty().lowercase()
        val hardware = Build.HARDWARE.orEmpty().lowercase()
        return fingerprint.startsWith("generic") ||
            fingerprint.startsWith("unknown") ||
            fingerprint.contains("sdk_gphone") ||
            model == "google_sdk" ||
            model.startsWith("sdk_gphone") ||
            model.contains("android sdk built for") ||
            product == "sdk" ||
            product == "google_sdk" ||
            product.startsWith("sdk_") ||
            product.startsWith("vbox86") ||
            product.contains("gphone") ||
            hardware == "goldfish" || hardware == "ranchu"
    }
}

/**
 * Publishes the phone as a Bonjour service (`_wamc._tcp`) on Wi-Fi so the
 * Mac discovers it automatically. Owns the NSD registration, the Wi-Fi
 * multicast lock (some firmware filters mDNS without it), and network
 * change handling: register on Wi-Fi available, unregister on loss.
 *
 * The AWC1 stream itself is served by the existing socket transport on
 * the same port — this class is discovery only.
 */
class WifiDiscoveryAdvertiser internal constructor(
    private val appContext: Context,
    private val configProvider: () -> DiscoveryConfig,
    private val registrarOverride: NsdServiceRegistrar? = null,
    private val wifiAvailabilityOverride: (() -> Boolean)? = null,
) {
    constructor(context: Context, configProvider: () -> DiscoveryConfig) :
        this(context.applicationContext, configProvider, null, null)

    private val nsdManager =
        appContext.getSystemService(Context.NSD_SERVICE) as? NsdManager
    private val registrar = registrarOverride ?: nsdManager?.let(::NsdManagerRegistrar)
    private val wifiManager =
        appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private val connectivityManager =
        appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    @Volatile private var enabled = false
    @Volatile private var registered = false
    @Volatile private var wifiAvailable = false
    private var multicastLock: WifiManager.MulticastLock? = null

    private val registrationListener = object : NsdManager.RegistrationListener {
        override fun onServiceRegistered(info: NsdServiceInfo) {
            registered = true
            Log.i(TAG, "advertising as ${info.serviceName} (${info.serviceType})")
        }
        override fun onServiceUnregistered(info: NsdServiceInfo) {
            registered = false
        }
        override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
            registered = false
            Log.w(TAG, "NSD registration failed: $errorCode")
        }
        override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
            Log.w(TAG, "NSD unregistration failed: $errorCode")
        }
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            wifiAvailable = true
            registerIfNeeded()
        }
        override fun onLost(network: Network) {
            wifiAvailable = false
            unregisterIfNeeded()
        }
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            val hasWifi = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
            if (hasWifi && !wifiAvailable) {
                wifiAvailable = true
                registerIfNeeded()
            }
        }
    }

    /** Start advertising (idempotent). Follows Wi-Fi availability. */
    fun start() {
        if (enabled) return
        enabled = true
        runCatching {
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build()
            connectivityManager?.registerNetworkCallback(request, networkCallback)
        }.onFailure { Log.w(TAG, "network callback registration failed", it) }
        // Register immediately if already on Wi-Fi; the callback also fires
        // with onAvailable for existing networks, but don't rely on timing.
        wifiAvailable = isCurrentlyOnWifi()
        registerIfNeeded()
    }

    fun stop() {
        if (!enabled) return
        enabled = false
        runCatching { connectivityManager?.unregisterNetworkCallback(networkCallback) }
        unregisterIfNeeded()
    }

    /** Restart the advertisement (e.g. identity/metadata changed). */
    fun refresh() {
        if (!enabled) return
        unregisterIfNeeded()
        registerIfNeeded()
    }

    private fun isCurrentlyOnWifi(): Boolean {
        wifiAvailabilityOverride?.let { return runCatching(it).getOrDefault(false) }
        val cm = connectivityManager ?: return false
        if (Build.VERSION.SDK_INT >= 29) {
            val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
            return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        }
        @Suppress("DEPRECATION")
        return cm.activeNetworkInfo?.type == ConnectivityManager.TYPE_WIFI
    }

    @Synchronized
    private fun registerIfNeeded() {
        val nsd = registrar ?: return
        if (!enabled || !wifiAvailable || registered) return
        val config = configProvider()
        if (!WamcDiscovery.isValidId(config.id)) {
            Log.w(TAG, "not advertising: invalid device id")
            return
        }
        acquireMulticastLock()
        val info = NsdServiceInfo().apply {
            serviceName = WamcDiscovery.instanceName(config.model, config.id)
            serviceType = WamcDiscovery.SERVICE_TYPE
            port = config.port
            WamcDiscovery.txtAttributes(
                id = config.id, model = config.model,
                brand = config.brand, sdk = config.sdk, port = config.port,
                emulator = config.emulator,
            ).forEach { (key, value) -> setAttribute(key, value) }
        }
        runCatching {
            nsd.registerService(info, registrationListener)
            // Optimistically mark until onServiceRegistered confirms; a
            // failure callback clears it and the next network event retries.
            registered = true
        }.onFailure {
            registered = false
            releaseMulticastLock()
            Log.w(TAG, "registerService failed", it)
        }
    }

    @Synchronized
    private fun unregisterIfNeeded() {
        val nsd = registrar ?: return
        if (!registered) { releaseMulticastLock(); return }
        runCatching { nsd.unregisterService(registrationListener) }
            .onFailure { Log.w(TAG, "unregisterService failed", it) }
        registered = false
        releaseMulticastLock()
    }

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        runCatching {
            multicastLock = wifiManager?.createMulticastLock(LOCK_TAG)?.apply {
                setReferenceCounted(false)
                acquire()
            }
        }.onFailure { Log.w(TAG, "multicast lock acquire failed", it) }
    }

    private fun releaseMulticastLock() {
        runCatching { if (multicastLock?.isHeld == true) multicastLock?.release() }
        multicastLock = null
    }

    private companion object {
        const val TAG = "AWC"
        const val LOCK_TAG = "wamc-mdns"
    }
}

/** Narrow NSD boundary keeps registration policy testable without Android discovery hardware. */
internal interface NsdServiceRegistrar {
    fun registerService(info: NsdServiceInfo, listener: NsdManager.RegistrationListener)
    fun unregisterService(listener: NsdManager.RegistrationListener)
}

private class NsdManagerRegistrar(private val manager: NsdManager) : NsdServiceRegistrar {
    override fun registerService(info: NsdServiceInfo, listener: NsdManager.RegistrationListener) {
        manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    override fun unregisterService(listener: NsdManager.RegistrationListener) {
        manager.unregisterService(listener)
    }
}
