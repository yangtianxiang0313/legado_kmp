package io.legado.kmp.shared.di

import io.legado.kmp.shared.facade.BookDetailFacade
import io.legado.kmp.shared.facade.BookExportFacade
import io.legado.kmp.shared.facade.BookImageFacade
import io.legado.kmp.shared.facade.BookSourceDebugFacade
import io.legado.kmp.shared.facade.BookshelfFacade
import io.legado.kmp.shared.facade.LocalBookFileNameFacade
import io.legado.kmp.shared.facade.DiscoveryFacade
import io.legado.kmp.shared.facade.ReaderFacade
import io.legado.kmp.shared.facade.ReadRecordFacade
import io.legado.kmp.shared.facade.ReplaceRuleFacade
import io.legado.kmp.shared.facade.RemoteBookFacade
import io.legado.kmp.shared.facade.RuntimeFacade
import io.legado.kmp.shared.facade.RssFacade
import io.legado.kmp.shared.facade.SearchFacade
import io.legado.kmp.shared.facade.SettingsFacade
import io.legado.kmp.shared.facade.SourceManagementFacade
import io.legado.kmp.shared.facade.WebDavRemoteBookDownloader
import io.legado.kmp.shared.facade.BookmarkFacade
import io.legado.kmp.shared.facade.CacheFacade
import io.legado.kmp.shared.facade.LogFacade
import io.legado.kmp.shared.facade.AudioPlayFacade
import io.legado.kmp.shared.facade.MangaReaderFacade
import io.legado.kmp.shared.data.database.DriverFactory
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.data.repository.*
import io.legado.kmp.shared.domain.localbook.ArchiveBookRecovery
import io.legado.kmp.shared.domain.localbook.RetainedArchiveBookStorage
import io.legado.kmp.shared.domain.localbook.LocalBookFileResolver
import io.legado.kmp.shared.domain.localbook.LocalBookFileNameResolver
import io.legado.kmp.shared.domain.localbook.LocalBookFileStore
import io.legado.kmp.shared.domain.localbook.EpubBookParser
import io.legado.kmp.shared.domain.localbook.PdfBookParser
import io.legado.kmp.shared.domain.localbook.UmdBookParser
import io.legado.kmp.shared.domain.localbook.MobiBookParser
import io.legado.kmp.shared.domain.localbook.RemoteBookDownloader
import io.legado.kmp.shared.domain.localbook.ZipEpubBookParser
import io.legado.kmp.shared.domain.localbook.createPlatformMobiBookParser
import io.legado.kmp.shared.domain.localbook.createPlatformPdfBookParser
import io.legado.kmp.shared.domain.localbook.createPlatformUmdBookParser
import io.legado.kmp.shared.domain.runtime.BookCacheService
import io.legado.kmp.shared.domain.runtime.AudioPlayService
import io.legado.kmp.shared.domain.runtime.DownloadService
import io.legado.kmp.shared.domain.runtime.ManagedBookCacheService
import io.legado.kmp.shared.domain.runtime.ManagedAudioPlayService
import io.legado.kmp.shared.domain.runtime.ManagedDownloadService
import io.legado.kmp.shared.domain.runtime.ManagedReadAloudService
import io.legado.kmp.shared.domain.runtime.ManagedRemoteLibraryService
import io.legado.kmp.shared.domain.runtime.ManagedSourceCheckService
import io.legado.kmp.shared.domain.runtime.ReadAloudService
import io.legado.kmp.shared.domain.runtime.RemoteLibraryService
import io.legado.kmp.shared.domain.runtime.SourceCheckBackend
import io.legado.kmp.shared.domain.runtime.SourceCheckService
import io.legado.kmp.shared.domain.repository.*
import io.legado.kmp.shared.domain.rss.RssService
import io.legado.kmp.shared.domain.usecase.*
import io.legado.kmp.shared.network.LegadoHttpClient
import io.legado.kmp.shared.network.HttpUseCase
import io.legado.kmp.shared.network.InteractiveSourceCapability
import io.legado.kmp.shared.network.MediaRequestExecutor
import io.legado.kmp.shared.network.ProxyRequestExecutor
import io.legado.kmp.shared.network.SourceRequestExecutor
import io.legado.kmp.shared.network.UploadRequestExecutor
import io.legado.kmp.shared.network.WebViewRequestExecutor
import io.legado.kmp.shared.platform.AppFilesDirectory
import io.legado.kmp.shared.platform.FileAccess
import io.legado.kmp.shared.platform.FileAccessLocalBookFileStore
import io.legado.kmp.shared.source.SourceStateStore
import io.legado.kmp.shared.image.BasicImageSizeDecoder
import io.legado.kmp.shared.image.FileImageDiskCache
import io.legado.kmp.shared.image.ImageDiskCache
import io.legado.kmp.shared.image.ImageLruCache
import io.legado.kmp.shared.image.ImageSizeDecoder
import io.legado.kmp.shared.scripting.LegacyImageDecoder
import io.legado.kmp.shared.scripting.LegacySourceJsRuntime
import io.legado.kmp.shared.scripting.SourceJsRuntime
import org.koin.core.module.Module
import org.koin.dsl.module

/**
 * Core DI module
 * Contains database, network and infrastructure
 */
val coreModule = module {
    // Database instance - DriverFactory is injected from platform module
    single {
        val driverFactory = get<DriverFactory>()
        LegadoDatabase(
            driver = driverFactory.createDriver(LegadoDatabase.DATABASE_NAME)
        )
    }

    // HTTP Client
    single { LegadoHttpClient(preferencesStore = get()) }
    single { HttpUseCase(get()) }

    // HTML Parser
    single { io.legado.kmp.shared.network.HtmlParser() }

    // JS Executor
    single { io.legado.kmp.shared.network.JsExecutor() }
    single { LegacyImageDecoder() }

    // Image caches and decoder
    single { ImageLruCache() }
    single<ImageDiskCache> { FileImageDiskCache(get(), get()) }
    single<ImageSizeDecoder> { BasicImageSizeDecoder(get()) }

    // URL Analyzer
    single { io.legado.kmp.shared.network.AnalyzeUrl() }
    single { io.legado.kmp.shared.network.SourceHeaderResolver(get(), preferencesStore = get()) }

    single { SourceStateStore(get(), get(), getOrNull()) }
    single<SourceJsRuntime> {
        LegacySourceJsRuntime(
            sourceStateStore = get(),
            cookieRepository = get()
        )
    }

    // Source request executor
    single {
        SourceRequestExecutor(
            httpUseCase = get(),
            cookieRepository = get(),
            jsExecutor = get(),
            sourceStateStore = get(),
            headerResolver = get(),
            sourceJsRuntime = get(),
            interactiveCapability = getOrNull<InteractiveSourceCapability>(),
            webViewRequestExecutor = getOrNull<WebViewRequestExecutor>(),
            proxyRequestExecutor = getOrNull<ProxyRequestExecutor>(),
            mediaRequestExecutor = getOrNull<MediaRequestExecutor>(),
            uploadRequestExecutor = getOrNull<UploadRequestExecutor>(),
            fileAccess = getOrNull<FileAccess>(),
            appFilesDirectory = getOrNull<AppFilesDirectory>(),
        )
    }
    single<io.legado.kmp.shared.network.LegacyJsConnectGateway> { get<SourceRequestExecutor>() }
}

/**
 * Network layer DI module
 */
val networkModule = module {
    // Network utilities included in coreModule
}

/**
 * Data layer DI module
 * Contains repository implementations
 */
val dataModule = module {
    // Book sources
    single<BookSourceRepository> { BookSourceRepositoryImpl(get()) }

    // Books
    single<BookRepository> { BookRepositoryImpl(get()) }
    single<BookChapterRepository> { BookChapterRepositoryImpl(get()) }

    // Book groups
    single<BookGroupRepository> { BookGroupRepositoryImpl(get()) }

    // Bookmarks
    single<BookmarkRepository> { BookmarkRepositoryImpl(get()) }
    single<ChapterContentRepository> { ChapterContentRepositoryImpl(get(), get(), chapterRepository = get()) }
    single<CacheRepository> { CacheRepositoryImpl(get()) }
    single<CookieRepository> { CookieRepositoryImpl(get()) }
    single<ReadRecordRepository> { ReadRecordRepositoryImpl(get()) }
    single<SearchRepository> { SearchRepositoryImpl(get()) }
    single<SearchKeywordRepository> { SearchKeywordRepositoryImpl(get()) }
    single<TxtTocRuleRepository> { TxtTocRuleRepositoryImpl(get()) }
    single<RssSourceRepository> { RssSourceRepositoryImpl(get()) }
    single<RssArticleRepository> { RssArticleRepositoryImpl(get()) }
    single<RssStarRepository> { RssStarRepositoryImpl(get()) }
    single<RssReadRecordRepository> { RssReadRecordRepositoryImpl(get()) }
    single<BookChapterReviewRepository> { BookChapterReviewRepositoryImpl(get()) }
    single<DictRuleRepository> { DictRuleRepositoryImpl(get()) }
    single<HttpTTSRepository> { HttpTTSRepositoryImpl(get()) }
    single<KeyboardAssistRepository> { KeyboardAssistRepositoryImpl(get()) }
    single<RuleSubRepository> { RuleSubRepositoryImpl(get()) }
    single<ServerRepository> { ServerRepositoryImpl(get()) }

    // Replace rules
    single<ReplaceRuleRepository> { ReplaceRuleRepositoryImpl(get()) }

    single<WebBookRepository> { WebBookRepositoryImpl(get(), get(), get(), get(), get(), get()) }
    single { RssService(get(), get(), get(), get(), get(), get()) }
}

/**
 * Domain layer DI module
 * Contains use cases
 */
val domainModule = module {
    // Book sources
    factory { GetBookSourcesUseCase(get()) }
    factory { GetExploreKindsUseCase(get(), get(), get(), get()) }
    factory { SaveBookSourceUseCase(get()) }
    factory { DeleteBookSourceUseCase(get()) }

    // Books
    factory { GetBooksUseCase(get()) }
    factory { GetBookUseCase(get()) }
    factory { SaveBookUseCase(get()) }
    factory { DeleteBookUseCase(get()) }
    factory { UpdateReadingProgressUseCase(get()) }
    factory { SearchBooksUseCase(get()) }
    factory { SearchUseCase(get()) }
    factory { GetChaptersUseCase(get()) }
    factory { ObserveBookChaptersUseCase(get()) }
    factory { SaveChaptersUseCase(get()) }

    // Book groups
    factory { GetBookGroupsUseCase(get()) }
    factory { SaveBookGroupUseCase(get()) }
    factory { DeleteBookGroupUseCase(get()) }

    // Bookmarks
    factory { GetBookmarksUseCase(get()) }
    factory { SaveBookmarkUseCase(get()) }
    factory { DeleteBookmarkUseCase(get()) }
    factory { GetCacheUseCase(get()) }
    factory { SaveCacheUseCase(get()) }
    factory { DeleteCacheUseCase(get()) }
    factory { GetCookiesUseCase(get()) }
    factory { SaveCookieUseCase(get()) }
    factory { DeleteCookieUseCase(get()) }
    factory { GetReadRecordsUseCase(get()) }
    factory { SaveReadRecordUseCase(get()) }
    factory { DeleteReadRecordUseCase(get()) }
    factory { GetSearchKeywordsUseCase(get()) }
    factory { SaveSearchKeywordUseCase(get()) }
    factory { DeleteSearchKeywordUseCase(get()) }
    factory { GetTxtTocRulesUseCase(get()) }
    factory { SaveTxtTocRuleUseCase(get()) }
    factory { DeleteTxtTocRuleUseCase(get()) }
    factory { GetBookChapterReviewsUseCase(get()) }
    factory { SaveBookChapterReviewUseCase(get()) }
    factory { DeleteBookChapterReviewUseCase(get()) }
    factory { GetDictRulesUseCase(get()) }
    factory { SaveDictRuleUseCase(get()) }
    factory { DeleteDictRuleUseCase(get()) }
    factory { GetHttpTTSUseCase(get()) }
    factory { SaveHttpTTSUseCase(get()) }
    factory { DeleteHttpTTSUseCase(get()) }
    factory { GetKeyboardAssistsUseCase(get()) }
    factory { SaveKeyboardAssistUseCase(get()) }
    factory { DeleteKeyboardAssistUseCase(get()) }
    factory { GetRuleSubsUseCase(get()) }
    factory { SaveRuleSubUseCase(get()) }
    factory { DeleteRuleSubUseCase(get()) }
    factory { GetServersUseCase(get()) }
    factory { SaveServerUseCase(get()) }
    factory { DeleteServerUseCase(get()) }

    // Replace rules
    factory { GetReplaceRulesUseCase(get()) }
    factory { SaveReplaceRuleUseCase(get()) }
    factory { DeleteReplaceRuleUseCase(get()) }
    factory { ApplyReplaceRulesUseCase(get()) }

    // WebBook operations
    factory { ExploreBooksUseCase(get()) }
    factory { GetBookInfoUseCase(get()) }
    factory { RefreshBookInfoUseCase(get()) }
    factory { GetChapterListUseCase(get()) }
    factory {
        FetchChapterListUseCase(
            repository = get(),
            chapterRepository = get(),
            applyReplaceRulesUseCase = get(),
            sourceStateStore = get(),
            jsExecutor = get(),
            sourceJsRuntime = get(),
            connectGateway = get(),
            headerResolver = get()
        )
    }
    factory { FetchChapterListContractUseCase(get()) }
    factory { GetChapterContentUseCase(get()) }
    factory { LoadChapterContentUseCase(get()) }
    factory { GetPayActionUseCase(get(), get(), get(), get(), get()) }
    factory { SearchWebBooksUseCase(get()) }
    factory { ObserveEnabledRssSourcesUseCase(get()) }
    factory { GetRssSortUrlsUseCase(get()) }
    factory { FetchRssArticlesUseCase(get()) }
    factory { FetchRssContentUseCase(get()) }
    factory { MarkRssArticleReadUseCase(get()) }
    factory { GetRssReadRecordsUseCase(get()) }
    factory { CountRssReadRecordsUseCase(get()) }
    factory { ClearRssReadRecordsUseCase(get()) }
    factory { ObserveRssFavoritesUseCase(get()) }
    factory { ObserveRssFavoriteGroupsUseCase(get()) }
    factory { ObserveRssFavoritesByGroupUseCase(get()) }
    factory { ToggleRssFavoriteUseCase(get()) }
    factory { AddRssFavoriteUseCase(get()) }
    factory { UpdateRssFavoriteUseCase(get()) }
    factory { DeleteRssFavoriteUseCase(get()) }

    // Source state operations
    factory { GetLoginHeaderUseCase(get()) }
    factory { PutLoginHeaderUseCase(get()) }
    factory { GetLoginInfoUseCase(get()) }
    factory { PutLoginInfoUseCase(get()) }
    factory { ExecuteLoginUrlUseCase(get(), get(), get(), get()) }
    factory { GetSourceVariableUseCase(get()) }
    factory { PutSourceVariableUseCase(get()) }
    factory { GetSourceValueUseCase(get()) }
    factory { PutSourceValueUseCase(get()) }
}

/**
 * Rule Engine DI module
 */
val ruleEngineModule = module {
    // Core rule engine
    factory { io.legado.kmp.shared.analyze.AnalyzeRule() }

    // Parsers
    factory { io.legado.kmp.shared.analyze.parser.CssRuleParser() }
    factory { io.legado.kmp.shared.analyze.parser.RegexRuleParser() }
    factory { io.legado.kmp.shared.analyze.parser.JsonPathParser() }
    factory { io.legado.kmp.shared.analyze.parser.XPathParser() }
    factory { io.legado.kmp.shared.analyze.parser.JsRuleParser(get(), get()) }
}

val localBookModule = module {
    single<LocalBookFileStore> { FileAccessLocalBookFileStore(get()) }
    single { LocalBookFileNameResolver(preferencesStore = get(), jsExecutor = get()) }
    single { RetainedArchiveBookStorage(get(), get()) }
    single<ArchiveBookRecovery> { get<RetainedArchiveBookStorage>() }
    single<RemoteBookDownloader> { WebDavRemoteBookDownloader(get(), get(), get()) }
    single {
        val exploreKinds: GetExploreKindsUseCase = get()
        SourceCheckBackend(get(), get(), resolveExploreUrl = { source ->
            exploreKinds(source).getOrThrow().firstOrNull { !it.url.isNullOrBlank() }?.url
        })
    }
    single<SourceCheckService> { ManagedSourceCheckService(get(), get(), get(), get()) }
    single<BookCacheService> { ManagedBookCacheService(get()) }
    single<ReadAloudService> { ManagedReadAloudService(get(), get()) }
    single<AudioPlayService> { ManagedAudioPlayService(get()) }
    single<DownloadService> { ManagedDownloadService(get()) }
    single<RemoteLibraryService> { ManagedRemoteLibraryService(get(), get()) }
    factory { LocalBookFileResolver(get(), get(), get()) }
    factory { io.legado.kmp.shared.domain.localbook.TxtBookParser() }
    single { ZipEpubBookParser(get()) }
    single<EpubBookParser> { get<ZipEpubBookParser>() }
    single<PdfBookParser> { createPlatformPdfBookParser() }
    single<UmdBookParser> { createPlatformUmdBookParser() }
    single<MobiBookParser> { createPlatformMobiBookParser(get()) }
    factory { ParseTxtBookUseCase(get(), get()) }
    factory { LoadTxtChapterContentUseCase(get()) }
    factory { ParseTxtLocalFileUseCase(get(), get()) }
    factory { LoadTxtLocalChapterContentUseCase(get(), get()) }
    factory { ParseEpubLocalFileUseCase(get(), get()) }
    factory { io.legado.kmp.shared.domain.usecase.EpubCatalogReflowPreparer(get(), get(), get(), get(), get(), get(), get(), get()) }
    factory { LoadEpubLocalChapterContentUseCase(get(), get()) }
    factory { ParsePdfLocalFileUseCase(get(), get()) }
    factory { LoadPdfLocalChapterContentUseCase(get(), get()) }
    factory { RenderPdfLocalPageImageUseCase(get(), get()) }
    factory { ParseUmdLocalFileUseCase(get(), get()) }
    factory { LoadUmdLocalChapterContentUseCase(get(), get()) }
    factory { ParseMobiLocalFileUseCase(get(), get(), get(), get()) }
    factory { LoadMobiLocalChapterContentUseCase(get(), get()) }
    factory { IsLocalBookModifiedUseCase(get()) }
}

val facadeModule = module {
    single { io.legado.kmp.shared.facade.CacheChapterImages(get(), get(), get()) }
    single { io.legado.kmp.shared.facade.CloudBackupFacade(get(), get()) }
    single { io.legado.kmp.shared.facade.ArchiveBookImportFacade(get(), get(), get(), get(), get(), get(), get(), get(), localBookFileNameResolver = get()) }
    factory { io.legado.kmp.shared.facade.LocalBookRelinkFacade(get(), get(), get(), get(), get(), get(), get(), get(), get(), get()) }
    factory { LocalBookFileNameFacade(get(), get()) }
    factory { io.legado.kmp.shared.facade.DirectLinkUploadFacade(get(), get()) }
    factory { io.legado.kmp.shared.facade.BackupCapabilitiesFacade(get(), get(), get(), get(), get(), get(), get(), get(), get()) }
    factory { ContentProcessor(get()) }
    factory { BookshelfFacade(get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), getOrNull(), getOrNull(), localBookFileNameResolver = get()) }
    factory { SearchFacade(get(), get(), get(), get(), get(), get(), get(), get(), get()) }
    factory { DiscoveryFacade(get(), get(), get()) }
    factory { io.legado.kmp.shared.facade.DictionaryFacade(get(), get(), get(), get()) }
    factory { BookDetailFacade(get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), parseEpubLocalFileUseCase = get(), preferencesStore = get(), contentProcessor = get(), sourceStateStore = get(), parseMobiLocalFileUseCase = get(), parsePdfLocalFileUseCase = get(), parseUmdLocalFileUseCase = get(), epubCatalogReflowPreparer = get()) }
    factory { ReaderFacade(get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), chapterImages = get()) }
    factory { RssFacade(get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get()) }
    factory { SettingsFacade(get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get()) }
    factory { RuntimeFacade(get(), get(), get(), get(), get(), get()) }
    factory { RemoteBookFacade(get(), get(), get(), getOrNull(), getOrNull()) }
    factory { BookImageFacade(get(), get(), get<io.legado.kmp.shared.network.LegacyJsConnectGateway>(), get(), get(), get(), get(), preferencesStore = get(), epubBookParser = get(), localBookFileResolver = get(), mobiBookParser = get()) }
    factory { BookExportFacade(get(), get(), get(), get(), get(), get(), get(), get(), get()) }
    factory { SourceManagementFacade(get(), get(), get(), get(), get(), get(), get()) }
    factory { io.legado.kmp.shared.facade.SourceLoginFacade(get(), get(), get(), get(), get(), get()) }
    factory { BookSourceDebugFacade(get(), get(), get(), get(), get()) }
    factory { ReplaceRuleFacade(get(), get(), get()) }
    factory { BookmarkFacade(get()) }
    factory { ReadRecordFacade(get(), get(), get()) }
    factory { LogFacade() }
    factory { CacheFacade(get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), chapterImages = get(), bookExporter = get()) }
    factory { AudioPlayFacade(get(), get(), get(), get(), get(), get()) }
    factory { io.legado.kmp.shared.facade.HttpSpeechFacade(get(), get(), get()) }
    factory { MangaReaderFacade(get(), get(), get(), get(), get(), get(), get(), get(), get(), get(), get()) }
}

/**
 * Full DI module
 */
val SharedModule: List<Module> = coreModule + networkModule + dataModule + domainModule + ruleEngineModule + localBookModule + facadeModule

/**
 * All Koin modules for the shared module
 */
val koinModules: List<Module> = SharedModule + platformModule
