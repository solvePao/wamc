package com.androidwebcam.app

import com.androidwebcam.app.transport.WamcDiscovery
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DiscoveryTest {

    @Test fun shortIdTakesFirstFourAlnumLowercased() {
        assertEquals("a1b2", WamcDiscovery.shortId("A1B2C3D4-1111"))
        assertEquals("0000", WamcDiscovery.shortId("---"))
    }

    @Test fun instanceNameCombinesModelAndShortId() {
        assertEquals(
            "WAMC-SM-E236B-a1b2",
            WamcDiscovery.instanceName("SM-E236B", "a1b2c3d4-0000"))
        assertEquals(
            "WAMC-Android-zz99",
            WamcDiscovery.instanceName("  ", "zz99aaaa"))
    }

    @Test fun txtAttributesCarryContractKeys() {
        val txt = WamcDiscovery.txtAttributes(
            id = "device-1", model = "SM-E236B", brand = "samsung", sdk = 34)
        assertEquals("2", txt["v"])
        assertEquals("device-1", txt["id"])
        assertEquals("SM-E236B", txt["model"])
        assertEquals("samsung", txt["brand"])
        assertEquals("34", txt["sdk"])
        assertEquals("27183", txt["port"])
        assertEquals("avc,hevc;configV2", txt["caps"])
    }

    @Test fun sanitizeStripsSeparatorsAndControls() {
        assertEquals("SM E236B x", WamcDiscovery.sanitize("SM;E236B=x"))
        assertEquals("a b", WamcDiscovery.sanitize("a\n\t b"))
    }

    @Test fun idValidation() {
        assertTrue(WamcDiscovery.isValidId("550e8400-e29b-41d4-a716"))
        assertFalse(WamcDiscovery.isValidId(""))
        assertFalse(WamcDiscovery.isValidId(null))
        assertFalse(WamcDiscovery.isValidId("has space"))
        assertFalse(WamcDiscovery.isValidId("x".repeat(65)))
    }

    @Test fun serviceTypeMatchesMacBrowser() {
        assertEquals("_wamc._tcp.", WamcDiscovery.SERVICE_TYPE)
        assertEquals("_wamc._tcp", WamcDiscovery.SERVICE_TYPE_MAC)
        assertEquals(27183, WamcDiscovery.PORT)
    }
}
