package io.legado.kmp.shared.di

import io.legado.kmp.shared.data.database.DriverFactory
import io.legado.kmp.shared.network.InteractiveSourceCapability
import io.legado.kmp.shared.network.IosInteractiveSourceCapability
import io.legado.kmp.shared.network.IosMediaRequestExecutor
import io.legado.kmp.shared.network.IosProxyRequestExecutor
import io.legado.kmp.shared.network.IosUploadRequestExecutor
import io.legado.kmp.shared.network.IosWebViewRequestExecutor
import io.legado.kmp.shared.network.MediaRequestExecutor
import io.legado.kmp.shared.network.ProxyRequestExecutor
import io.legado.kmp.shared.network.UploadRequestExecutor
import io.legado.kmp.shared.network.WebViewRequestExecutor
import io.legado.kmp.shared.platform.FileAccess
import io.legado.kmp.shared.platform.AppFilesDirectory
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.preferences.IosAppPreferencesStore
import io.legado.kmp.shared.source.IosSourceStateCipher
import io.legado.kmp.shared.source.SourceStateCipher
import org.koin.dsl.module

/**
 * iOS-specific Koin module
 */
actual val platformModule = module {
    // Database driver factory for iOS
    single { createPlatformBinding("DriverFactory") { DriverFactory() } }
    single { createPlatformBinding("FileAccess") { FileAccess() } }
    single { createPlatformBinding("AppFilesDirectory") { AppFilesDirectory() } }
    single<AppPreferencesStore> { createPlatformBinding("AppPreferencesStore") { IosAppPreferencesStore() } }
    single<SourceStateCipher> { createPlatformBinding("SourceStateCipher") { IosSourceStateCipher() } }
    single<WebViewRequestExecutor> { IosWebViewRequestExecutor(get(), get(), get()) }
    single<ProxyRequestExecutor> { IosProxyRequestExecutor() }
    single<MediaRequestExecutor> { IosMediaRequestExecutor(get()) }
    single<UploadRequestExecutor> { IosUploadRequestExecutor() }
    single<InteractiveSourceCapability> {
        IosInteractiveSourceCapability(
            httpUseCase = get(),
            cookieRepository = get(),
            webViewRequestExecutor = get(),
            proxyRequestExecutor = get(),
            mediaRequestExecutor = get(),
            headerResolver = get(),
            sourceRequestExecutor = { get() },
            sourceStateStore = get(),
        )
    }
}

private inline fun <T> createPlatformBinding(
    name: String,
    factory: () -> T,
): T {
    return try {
        factory()
    } catch (throwable: Throwable) {
        throw IllegalStateException("Failed to initialize iOS binding: $name", throwable)
    }
}
