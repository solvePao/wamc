package com.androidwebcam.app.transport

import java.util.UUID

/**
 * Bonjour / DNS-SD discovery contract for Wi-Fi auto-discovery.
 *
 * The phone publishes service type [_wamc._tcp] so the macOS app can browse
 * for it with `NWBrowser` and connect to the Bonjour endpoint directly —
 * no manual IP entry. The stable per-install [device id][newDeviceId]
 * distinguishes two identical phones and anchors Mac-side trust.
 *
 * Pure and dependency-free so it is unit-tested without Android APIs.
 * See shared/protocol/PROTOCOL.md "Discovery (Bonjour)".
 */
object WamcDiscovery {
    /** NSD service type. Android NSD expects the trailing dot form. */
    const val SERVICE_TYPE = "_wamc._tcp."
    /** Service type as browsed by macOS (`NWBrowser`). */
    const val SERVICE_TYPE_MAC = "_wamc._tcp"
    const val PORT = 27183
    const val PROTOCOL_VERSION = "2"

    /** Fresh stable identity for a new install. Persist the result. */
    fun newDeviceId(): String = UUID.randomUUID().toString()

    fun isValidId(id: String?): Boolean {
        if (id.isNullOrBlank() || id.length > 64) return false
        return id.all { it.isLetterOrDigit() || it == '-' || it == '_' }
    }

    /** First 4 hex/identifier characters, lowercased, for display names. */
    fun shortId(id: String): String =
        id.filter { it.isLetterOrDigit() }.take(4).lowercase().ifEmpty { "0000" }

    /** Bonjour instance name, e.g. `WAMC-SM-E236B-a1b2`. */
    fun instanceName(model: String, id: String): String {
        val cleanModel = sanitize(model).ifEmpty { "Android" }
        return "WAMC-$cleanModel-${shortId(id)}"
    }

    /**
     * TXT record advertised with the service. Keys are short ASCII;
     * the Mac parses the same keys in `WamcDiscovery.parseTXT`.
     */
    fun txtAttributes(
        id: String,
        model: String,
        brand: String,
        sdk: Int,
        port: Int = PORT,
        emulator: Boolean = false,
    ): Map<String, String> = linkedMapOf(
        "v" to PROTOCOL_VERSION,
        "id" to id,
        "model" to sanitize(model),
        "brand" to sanitize(brand),
        "sdk" to sdk.toString(),
        "port" to port.toString(),
        "caps" to "avc,hevc;configV2",
        "emulator" to if (emulator) "1" else "0",
    )

    /** Keep Bonjour names/TXT values plain printable ASCII, single-spaced. */
    fun sanitize(raw: String): String = raw
        .map { ch -> if (ch.code in 32..126 && ch != ';' && ch != '=') ch else ' ' }
        .joinToString("")
        .replace(Regex("\\s+"), " ")
        .trim()
        .take(48)
}
