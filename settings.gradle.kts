pluginManagement {
    repositories {
        gradlePluginPortal()
        google()
        mavenCentral()
    }
    plugins {
        // Kotlin Multiplatform
        id("org.jetbrains.kotlin.multiplatform").version("2.1.0")
        id("org.jetbrains.kotlin.plugin.serialization").version("2.1.0")

        // SQLDelight
        id("app.cash.sqldelight").version("2.0.2")

        // KSP
        id("com.google.devtools.ksp").version("2.1.0-1.0.29")

        // Compose
        id("org.jetbrains.compose").version("1.7.0")
        id("org.jetbrains.kotlin.plugin.compose").version("2.1.0")
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven("https://maven.pkg.jetbrains.space/public/p/compose/dev")
        maven("https://maven.pkg.jetbrains.space/legado/com/fleeksoft/ksoup")
    }
}

rootProject.name = "legado-kmp"

include(":shared")
