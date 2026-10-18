package com.androidwebcam.app

import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.Network
import android.net.NetworkCapabilities
import com.androidwebcam.app.transport.DiscoveryConfig
import com.androidwebcam.app.transport.NsdServiceRegistrar
import com.androidwebcam.app.transport.WifiDiscoveryAdvertiser
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class WifiDiscoveryAdvertiserTest {
    @Test fun startRefreshStopAreIdempotentWithoutWifi() {
        val advertiser = WifiDiscoveryAdvertiser(RuntimeEnvironment.getApplication()) {
            DiscoveryConfig("invalid id", "Android", "", 35)
        }
        advertiser.start()
        advertiser.start()
        advertiser.refresh()
        advertiser.stop()
        advertiser.stop()
        advertiser.refresh()
    }

    @Test fun registrationFailureClearsStateAndRefreshRetries() {
        val registrar = FakeRegistrar()
        val advertiser = WifiDiscoveryAdvertiser(
            RuntimeEnvironment.getApplication(),
            { DiscoveryConfig("550e8400-e29b-41d4-a716-446655440000", "Android", "", 35) },
            registrar,
            { true },
        )
        advertiser.start()
        assertEquals(1, registrar.registerCalls)
        registrar.listener!!.onRegistrationFailed(NsdServiceInfo(), 1)

        advertiser.refresh()
        assertEquals(2, registrar.registerCalls)
        registrar.listener!!.onServiceRegistered(NsdServiceInfo())
        advertiser.stop()
        assertEquals(1, registrar.unregisterCalls)
    }

    @Test fun invalidDeviceIdNeverRegistersWithNsd() {
        val registrar = FakeRegistrar()
        val advertiser = WifiDiscoveryAdvertiser(
            RuntimeEnvironment.getApplication(),
            { DiscoveryConfig("invalid id", "Android", "", 35) },
            registrar,
            { true },
        )
        advertiser.start()
        assertEquals(0, registrar.registerCalls)
        advertiser.stop()
    }

    @Test fun networkCallbacksRetryRegistrationAndReportUnregistrationFailure() {
        val registrar = FakeRegistrar().apply {
            registrationFailure = IllegalStateException("NSD busy")
        }
        val advertiser = WifiDiscoveryAdvertiser(
            RuntimeEnvironment.getApplication(),
            { DiscoveryConfig("550e8400-e29b-41d4-a716-446655440000", "Android", "", 35) },
            registrar,
            { false },
        )
        advertiser.start()
        val callback = WifiDiscoveryAdvertiser::class.java.getDeclaredField("networkCallback")
            .apply { isAccessible = true }.get(advertiser) as android.net.ConnectivityManager.NetworkCallback
        val network = ReflectionHelpers.callConstructor(Network::class.java)
        callback.onAvailable(network)
        assertEquals(1, registrar.registerCalls)
        callback.onCapabilitiesChanged(network, NetworkCapabilities())
        callback.onLost(network)
        callback.onAvailable(network)
        assertEquals(2, registrar.registerCalls)

        registrar.registrationFailure = null
        callback.onLost(network)
        callback.onAvailable(network)
        assertEquals(3, registrar.registerCalls)
        registrar.listener!!.onServiceRegistered(NsdServiceInfo())
        registrar.unregisterFailure = IllegalStateException("NSD unregister failed")
        callback.onLost(network)
        registrar.listener!!.onUnregistrationFailed(NsdServiceInfo(), 2)
        advertiser.stop()
    }

    private class FakeRegistrar : NsdServiceRegistrar {
        var listener: NsdManager.RegistrationListener? = null
        var registerCalls = 0
        var unregisterCalls = 0
        var registrationFailure: RuntimeException? = null
        var unregisterFailure: RuntimeException? = null

        override fun registerService(info: NsdServiceInfo, listener: NsdManager.RegistrationListener) {
            registerCalls++
            this.listener = listener
            registrationFailure?.let { throw it }
        }

        override fun unregisterService(listener: NsdManager.RegistrationListener) {
            unregisterCalls++
            unregisterFailure?.let { throw it }
            listener.onServiceUnregistered(NsdServiceInfo())
        }
    }
}
