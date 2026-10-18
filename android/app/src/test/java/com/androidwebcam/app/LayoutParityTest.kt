package com.androidwebcam.app

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * Every view id present in one `activity_main` layout variant must exist in
 * the other. A missing id makes `findViewById` return null and crashed
 * startup (landscape lacked `cameraSelector`).
 */
class LayoutParityTest {

    private fun layoutFile(variant: String): File {
        val direct = File("src/main/res/$variant/activity_main.xml")
        if (direct.isFile) return direct
        return File("app/src/main/res/$variant/activity_main.xml")
    }

    private fun viewIds(variant: String): Set<String> {
        val text = layoutFile(variant).readText()
        return Regex("""android:id="@\+id/([^"]+)"""")
            .findAll(text).map { it.groupValues[1] }.toSet()
    }

    @Test
    fun portraitAndLandscapeDefineTheSameViewIds() {
        assertEquals(viewIds("layout"), viewIds("layout-land"))
    }

    @Test
    fun cameraSelectorExistsInBothVariants() {
        assertEquals(
            setOf("layout", "layout-land").map { viewIds(it).contains("cameraSelector") },
            listOf(true, true))
    }
}
