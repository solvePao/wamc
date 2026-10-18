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

val debugCoverageExecutionData = layout.buildDirectory.file(
    "outputs/unit_test_code_coverage/debugUnitTest/testDebugUnitTest.exec",
)

val validateDebugCoverageInputs = tasks.register("validateDebugCoverageInputs") {
    dependsOn("testDebugUnitTest")
    doLast {
        check(androidProductionClasses.files.any { it.extension == "class" }) {
            "No production classes found for Android coverage"
        }
        check(debugCoverageExecutionData.get().asFile.let { it.isFile && it.length() > 0 }) {
            "Missing or empty Android coverage execution data"
        }
    }
}

tasks.register<JacocoReport>("debugUnitTestCoverageReport") {
    dependsOn(validateDebugCoverageInputs)
    executionData.setFrom(debugCoverageExecutionData)
    sourceDirectories.setFrom(files("src/main/java"))
    classDirectories.setFrom(androidProductionClasses)
    reports {
        html.required.set(true)
        xml.required.set(true)
        csv.required.set(false)
    }
}

tasks.register<JacocoCoverageVerification>("verifyDebugUnitTestCoverage") {
    dependsOn(validateDebugCoverageInputs)
    executionData.setFrom(debugCoverageExecutionData)
    sourceDirectories.setFrom(files("src/main/java"))
    classDirectories.setFrom(androidProductionClasses)

    violationRules {
        rule {
            limit {
                counter = "LINE"
                value = "MISSEDCOUNT"
                maximum = "0".toBigDecimal()
            }
        }
    }
}

tasks.named("check") {
    dependsOn("verifyDebugUnitTestCoverage")
}

tasks.withType<Test>().configureEach {
    val workers = providers.gradleProperty("testWorkers").orElse("1").get().toInt()
    require(workers > 0) { "testWorkers must be a positive integer" }
    maxParallelForks = minOf(workers, Runtime.getRuntime().availableProcessors().coerceAtLeast(1))
    if (providers.gradleProperty("forceTestExecution").orNull == "true") {
        outputs.upToDateWhen { false }
    }
    extensions.configure<JacocoTaskExtension> {
        isIncludeNoLocationClasses = true
        includes = listOf("com.androidwebcam.app.*")
        excludes?.add("jdk.internal.*")
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
}
