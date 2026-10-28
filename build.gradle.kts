// Root build file for Legado KMP project

plugins {
    java
    alias(libs.plugins.kotlin.multiplatform) apply false
    alias(libs.plugins.kotlin.cocoapods) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.compose.multiplatform) apply false
    alias(libs.plugins.compose.compiler) apply false
    alias(libs.plugins.sqldelight) apply false
    id("org.jetbrains.kotlin.jvm") version "2.1.0" apply false
}

allprojects {
    group = "io.legado.kmp"
    version = "0.1.0"
}

// Configure Java toolchain for all projects
allprojects {
    plugins.withType<JavaPlugin> {
        configure<JavaPluginExtension> {
            toolchain {
                languageVersion.set(JavaLanguageVersion.of(17))
            }
        }
    }
}
