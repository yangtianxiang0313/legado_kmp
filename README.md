# Legado KMP

基于 [Legado](https://github.com/gedoor/legado) 的阅读业务和书源规则构建的 Kotlin Multiplatform 共享核心与 UIKit iOS 阅读器。非 Legado 官方 iOS 客户端。

项目仍在开发中，优先完善搜索、详情、目录、阅读、离线缓存和本地导入等消费链路。不承诺全部 Android 功能、第三方书源或界面细节已经完全兼容。

## 当前能力

- 书源导入与管理、多源搜索、发现、书架、目录与文字阅读。
- 阅读外观、分页、书签、正文搜索、替换规则、离线缓存与章节导出。
- TXT、EPUB、PDF、UMD、MOBI/AZW3 本地阅读，以及 ZIP、RAR、7z 导入。
- 漫画阅读、有声播放、朗读、RSS 订阅与收藏。
- WebDAV 备份恢复、阅读进度同步，以及普通文件后台下载和暂停续传。

上述能力不代表所有格式变体和网络环境均已验收。复杂鉴权书源、完整规则兼容、多设备同步竞争以及真机长时间运行仍需持续完善。普通文件后台下载也不等于所有文件型书源都已支持后台续传。

## 目录

| 路径 | 内容 |
| --- | --- |
| `shared/src/commonMain/` | 共享业务、书源规则、数据与网络运行时 |
| `shared/src/iosMain/` | iOS 平台实现 |
| `shared/src/nativeInterop/` | 系统库互操作声明 |
| `iosApp/iosApp/` | UIKit 应用与资源 |
| `iosApp/Pods/` | 已检入的 CocoaPods 依赖 |

## 构建

需要 macOS、完整 Xcode、JDK 17、CocoaPods，以及 iOS 16 或更高版本的模拟器。以下命令面向 Apple Silicon 的 arm64 模拟器。

```bash
git clone https://github.com/yangtianxiang0313/legado_kmp.git
cd legado_kmp

# 首次检出时生成本地 framework 占位并创建 workspace。
./gradlew :shared:generateDummyFramework
cd iosApp
pod install
cd ..

# 从设备列表中选择一个已安装的 iPhone 模拟器。
xcrun simctl list devices available
SIMULATOR_UDID="替换为模拟器 UDID"

unset OVERRIDE_KOTLIN_BUILD_IDE_SUPPORTED
xcodebuild -workspace iosApp/iosApp.xcworkspace -scheme iosApp \
  -configuration Debug -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID,arch=arm64" \
  -derivedDataPath /tmp/legado-kmp-build \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

也可以打开 `iosApp/iosApp.xcworkspace`，选择 `iosApp` scheme 和 iPhone 模拟器后运行。正常 App 构建会同步 Kotlin framework，不要用环境变量跳过 shared 构建。

首次构建需要访问 Gradle、Maven、CocoaPods 和 Swift Package 的依赖服务。真机运行需自行配置 Apple 开发团队与签名；仓库不提供开发者证书、账号或云服务凭据。

## 内容与反馈

书源规则与内容服务可能失效、限制访问或有独立使用条款，请自行确认所访问内容和服务的授权。仓库中的配置和示例不构成对第三方内容的授权。

反馈问题时请说明系统版本、设备、复现步骤和脱敏后的错误信息，不要提交账号密码、Cookie、签名下载链接或私人书籍正文。

## 开源快照与许可

公开仓库从本地消费功能提交 `f1b125d2` 的源码快照初始化，保留当前实现与第三方许可，不附带旧开发历史、回归样本、私人验收数据或本机未提交改动。此版本不是正式稳定发行版，也不代表所有功能已完成验收。

本项目以 GNU GPL v3 发布，完整条款见 [LICENSE](LICENSE)。上游来源与第三方许可说明见 [NOTICE.md](NOTICE.md)。
