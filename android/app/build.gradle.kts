import org.gradle.testing.jacoco.tasks.JacocoCoverageVerification
import org.gradle.testing.jacoco.tasks.JacocoReport
import org.gradle.api.tasks.testing.Test
import org.gradle.testing.jacoco.plugins.JacocoTaskExtension

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("jacoco")
}

val releaseVersion = groovy.json.JsonSlurper().parse(rootProject.file("../release.json")) as Map<*, *>

android {
    namespace = "com.androidwebcam.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.androidwebcam.app"
        minSdk = 26
        targetSdk = 35
        versionCode = (releaseVersion["build"] as Number).toInt()
        versionName = releaseVersion["version"] as String
    }
    buildFeatures { buildConfig = true }
    signingConfigs {
        create("distribution") {
            val keystore = System.getenv("ANDROID_KEYSTORE_PATH")
            if (!keystore.isNullOrBlank()) {
                storeFile = file(keystore)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }
    buildTypes {
        getByName("debug") {
            enableUnitTestCoverage = true
        }
        release {
            isMinifyEnabled = false
            if (!System.getenv("ANDROID_KEYSTORE_PATH").isNullOrBlank()) {
                signingConfig = signingConfigs.getByName("distribution")
            }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    testOptions {
        unitTests.isReturnDefaultValues = true
        unitTests.isIncludeAndroidResources = true
    }
}

val androidProductionClasses = files(
        layout.buildDirectory.dir("tmp/kotlin-classes/debug"),
        layout.buildDirectory.dir("intermediates/javac/debug/compileDebugJavaWithJavac/classes"),
    ).asFileTree.matching {
        exclude("**/R.class", "**/R\$*.class", "**/BuildConfig.*", "**/Manifest*.*")
    }

tasks.register<JacocoReport>("debugUnitTestCoverageReport") {
    dependsOn("testDebugUnitTest")
    executionData.setFrom(layout.buildDirectory.file(
        "outputs/unit_test_code_coverage/debugUnitTest/testDebugUnitTest.exec",
    ))
    sourceDirectories.setFrom(files("src/main/java"))
    classDirectories.setFrom(androidProductionClasses)
    reports {
        html.required.set(true)
        xml.required.set(true)
        csv.required.set(false)
    }
}

tasks.register<JacocoCoverageVerification>("verifyDebugUnitTestCoverage") {
    dependsOn("testDebugUnitTest")
    executionData.setFrom(layout.buildDirectory.file(
        "outputs/unit_test_code_coverage/debugUnitTest/testDebugUnitTest.exec",
    ))
    sourceDirectories.setFrom(files("src/main/java"))
    classDirectories.setFrom(androidProductionClasses)

    violationRules {
        rule {
            limit {
                counter = "LINE"
                value = "COVEREDRATIO"
                minimum = "0.90".toBigDecimal()
            }
        }
    }
}

tasks.named("check") {
    dependsOn("verifyDebugUnitTestCoverage")
}

tasks.withType<Test>().configureEach {
    extensions.configure<JacocoTaskExtension> {
        isIncludeNoLocationClasses = true
        excludes?.add("jdk.internal.*")
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
}
