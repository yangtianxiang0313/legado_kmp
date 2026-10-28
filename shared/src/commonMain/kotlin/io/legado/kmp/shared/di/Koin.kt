package io.legado.kmp.shared.di

import org.koin.core.context.startKoin
import org.koin.core.module.Module
import org.koin.dsl.KoinAppDeclaration

/**
 * Initialize Koin with shared and platform-specific modules
 */
fun initKoin(
    appDeclaration: KoinAppDeclaration = {},
    platformModule: Module
) {
    startKoin {
        appDeclaration()
        modules(
            sharedModules + platformModule
        )
    }
}

/**
 * Shared Koin modules (common to all platforms)
 */
val sharedModules = SharedModule

expect val platformModule: Module
