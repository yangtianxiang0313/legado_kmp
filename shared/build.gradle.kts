plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.kotlin.cocoapods)
    alias(libs.plugins.compose.multiplatform)
    alias(libs.plugins.compose.compiler)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.sqldelight)
}

kotlin {
    jvmToolchain(17)
    val iosTargets = listOf(
        iosX64(),
        iosArm64(),
        iosSimulatorArm64()
    )

    iosTargets.forEach { target ->
        val libxml2 = target.compilations.getByName("main").cinterops.create("libxml2") {
            defFile(project.file("src/nativeInterop/cinterop/libxml2.def"))
            packageName("io.legado.kmp.shared.libxml2")
            compilerOpts("-I${project.file("src/nativeInterop/cinterop").absolutePath}")
        }
        tasks.named(libxml2.interopProcessingTaskName) {
            inputs.file("src/nativeInterop/cinterop/libxml2_wrapper.h")
                .withPropertyName("libxml2WrapperHeader")
                .withPathSensitivity(PathSensitivity.RELATIVE)
        }
        val libarchive = target.compilations.getByName("main").cinterops.create("libarchive") {
            defFile(project.file("src/nativeInterop/cinterop/libarchive.def"))
            packageName("io.legado.kmp.shared.libarchive")
            compilerOpts("-I${project.file("src/nativeInterop/cinterop").absolutePath}")
        }
        tasks.named(libarchive.interopProcessingTaskName) {
            inputs.file("src/nativeInterop/cinterop/libarchive_wrapper.h")
                .withPropertyName("libarchiveWrapperHeader")
                .withPathSensitivity(PathSensitivity.RELATIVE)
        }
        target.binaries.framework {
            baseName = "shared"
            isStatic = true
            linkerOpts("-lsqlite3", "-larchive")
        }
    }

    cocoapods {
        summary = "Legado KMP shared business runtime"
        homepage = "https://github.com/legado-reader/legado"
        version = project.version.toString()
        ios.deploymentTarget = "16.0"
        extraSpecAttributes["libraries"] = "['c++', 'sqlite3', 'archive']"
        extraSpecAttributes["resources"] = "[]"
        framework {
            baseName = "shared"
            isStatic = true
        }
    }

    sourceSets {
        commonMain.dependencies {
            implementation(libs.kotlinx.coroutines.core)
            implementation(libs.kotlinx.serialization.json)
            implementation(libs.kotlinx.datetime)
            implementation(libs.bundles.ktor.common)
            implementation(libs.okio)
            implementation(libs.sqldelight.coroutines.extensions)
            implementation(libs.koin.core)
            implementation(libs.ksoup)
            implementation(libs.jsonpath4k)
            implementation(libs.quickjs.kt)
            implementation(compose.runtime)
            implementation(compose.foundation)
        }

        iosMain.dependencies {
            implementation(libs.sqldelight.native.driver)
            implementation(libs.ktor.client.darwin)
        }
    }
}

sqldelight {
    databases {
        create("LegadoDatabase") {
            packageName.set("io.legado.kmp.data.database")
        }
    }
    linkSqlite.set(true)
}
