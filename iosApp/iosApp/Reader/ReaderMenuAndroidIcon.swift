import UIKit

/// Unchanged VectorDrawable geometry from Legado at
/// commit 5f5d31404af9957684703747ecee2b91e7161f1d and its AppCompat 1.7.1
/// toolbar defaults; converted to template PDFs. See LegadoMenuIcons-NOTICE.txt.
enum ReaderMenuAndroidIcon: String, CaseIterable {
    case back = "ReaderMenuAndroidBack"  // AppCompat abc_ic_ab_back_material
    case download = "ReaderMenuAndroidDownload"  // ic_download_line (menu_download)
    case charset = "ReaderMenuAndroidCharset"  // ic_translate (menu_set_charset; autoMirrored absent/false)
    case more = "ReaderMenuAndroidMore"  // AppCompat abc_ic_menu_overflow_material
    case interfaceSetting = "ReaderMenuAndroidInterfaceSetting"  // ic_interface_setting
    case autoPage = "ReaderMenuAndroidAutoPage"  // ic_auto_page
    case autoPageStop = "ReaderMenuAndroidAutoPageStop"  // ic_auto_page_stop
    case findReplace = "ReaderMenuAndroidFindReplace"  // ic_find_replace
    case brightnessAuto = "ReaderMenuAndroidBrightnessAuto"  // ic_brightness_auto
    case readAloud = "ReaderMenuAndroidReadAloud"  // ic_read_aloud
    case toc = "ReaderMenuAndroidToc"  // ic_toc
    case settings = "ReaderMenuAndroidSettings"  // ic_settings (iv_setting)
    case daytime = "ReaderMenuAndroidDaytime"  // ic_daytime
    case brightness = "ReaderMenuAndroidBrightness"  // ic_brightness
    case search = "ReaderMenuAndroidSearch"  // ic_search
    case clear = "ReaderMenuAndroidClear"  // AppCompat abc_ic_clear_material (SearchView closeIcon)
    case refresh = "ReaderMenuAndroidRefresh"  // ic_refresh_black_24dp
    case changeSource = "ReaderMenuAndroidChangeSource"  // ic_exchange
    case swapHoriz = "ReaderMenuAndroidSwapHoriz"  // ic_swap_horiz

    func image(size: CGFloat = 24) -> UIImage? {
        guard size.isFinite, size > 0,
            let source = UIImage(named: rawValue)
        else { return nil }

        let targetSize = CGSize(width: size, height: size)
        let image: UIImage
        if source.size == targetSize {
            image = source
        } else {
            // Render the catalog vector at the requested point size and display scale.
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            image = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                source.withRenderingMode(.alwaysOriginal).draw(
                    in: CGRect(origin: .zero, size: targetSize))
            }
        }

        let template = image.withRenderingMode(.alwaysTemplate)
        // Only ic_search and AppCompat's back drawable declare android:autoMirrored="true".
        return self == .search || self == .back
            ? template.imageFlippedForRightToLeftLayoutDirection() : template
    }
}
