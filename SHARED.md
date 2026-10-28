# 共用规则（SHARED）

## 项目概览

`legado_kmp` 当前是精简后的 Kotlin Multiplatform shared core + UIKit iOS App 仓库。目标是保留可构建的共享业务运行时和 iOS 兼容层，删除测试、迁移文档、回归资源和辅助实验模块。

## 保留结构

| 路径 | 说明 |
|------|------|
| `shared/src/commonMain/` | KMP 共享核心代码 |
| `shared/src/iosMain/` | iOS actual 与平台实现 |
| `shared/src/nativeInterop/` | iOS cinterop 配置和头文件 |
| `shared/shared.podspec` | iOS CocoaPods 集成入口 |
| `iosApp/iosApp/` | UIKit iOS App 源码与资源 |
| `iosApp/iosApp.xcodeproj/`、`iosApp/iosApp.xcworkspace/` | iOS 工程 |
| `iosApp/Pods/` | 已检入的 CocoaPods 依赖 |
| `.codex/hooks/` | Codex Stop hook 自动推进对齐系统的入口 |
| `ALIGNMENT.md`、`alignment/` | 当前允许保留的 Android Legado 逐步对齐系统与功能树台账 |

## 构建与启动

在仓库根目录执行，需 macOS、完整 Xcode（已选择其 Command Line Tools）、可用的 iOS 16+ 模拟器及 JDK。以下流程面向 Apple Silicon 的 arm64 模拟器；使用已检入的 Pods 和 workspace。

- `gradlew` 优先使用显式设置的 `JAVA_HOME`，不会自动替换；无效路径会报错。未设置时，macOS 按 JDK 17、21 的顺序查找，依次检查 `java_home`、`${GRADLE_USER_HOME:-$HOME/.gradle}/jdks` 缓存、Homebrew 和 IDE 内置 JDK，并校验 `release` 版本信息；找不到则报错，不自动下载。项目 toolchain 仍为 17。
- Pod 构建脚本不覆盖 `JAVA_HOME`，统一交由 `gradlew` 选择。需要固定 JDK 时，在运行下列命令的终端中显式 `export JAVA_HOME="/实际/JDK/Contents/Home"`（推荐 17）。

```bash
# 查看设备并将 UDID 替换为一个可用的 iOS 模拟器 ID
xcrun simctl list devices available
SIMULATOR_UDID="替换为模拟器UDID"

# 可选：单独检查 shared 编译；完整 App 构建仍会执行 Kotlin 同步
./gradlew :shared:compileKotlinIosSimulatorArm64
unset OVERRIDE_KOTLIN_BUILD_IDE_SUPPORTED
xcodebuild -workspace iosApp/iosApp.xcworkspace -scheme iosApp \
  -configuration Debug -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID,arch=arm64" \
  -derivedDataPath /tmp/legado_kmp-derived-data \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build

# 设备已启动时跳过 boot
xcrun simctl boot "$SIMULATOR_UDID"
xcrun simctl bootstatus "$SIMULATOR_UDID" -b
open -a Simulator
xcrun simctl install "$SIMULATOR_UDID" \
  /tmp/legado_kmp-derived-data/Build/Products/Debug-iphonesimulator/iosApp.app
xcrun simctl launch "$SIMULATOR_UDID" io.legado.kmp.iosApp
```

正常构建依赖 Pod 脚本执行 `:shared:syncFramework`，不要通过 `OVERRIDE_KOTLIN_BUILD_IDE_SUPPORTED=YES` 跳过 Kotlin 构建。

`libxml2_wrapper.h` 已声明为 cinterop 任务输入，后续头文件变更会触发增量重建。若旧工作目录首次构建出现 wrapper 符号缺失或绑定不一致，先用 `./gradlew :shared:cinteropLibxml2IosSimulatorArm64 --info` 查看任务是否错误复用旧产物，再按需执行一次 `./gradlew :shared:cinteropLibxml2IosSimulatorArm64 --rerun-tasks` 并重试上述 App 构建；不要每次强制重建或清空全部缓存。

本仓库已删除单元测试和 UI 测试，不再运行测试闸门。

## 实现约束

- `commonMain` 只放共享业务逻辑，不直接依赖 UIKit、Foundation 或其他 iOS-only API。
- iOS 平台差异放在 `iosMain`、native interop 或 `iosApp` 中处理。
- 不新增测试、迁移、回归或 AI 工作流脚手架，除非用户明确要求恢复。
- Kotlin/Swift 业务文件超过 1200 行，或单个 ViewController 超过 800 行时，继续新增功能前必须先拆分；超过 2000 行视为必须优先偿还的技术债，只允许做拆分、构建修复或紧急回归修复。
- 拆分优先按职责边界落到同目录 companion 文件（如 `*Support`、`*Loading`、`*Paging`、`*Menu`、`*ReadAloud`），不得用 extension 文件继续堆同一职责。
- 允许维护 `ALIGNMENT.md` 与 `alignment/` 中的对齐台账；它们只记录功能树、源码证据、原子功能点和验收，不承载旧迁移/回归工作流。
- `.codex/hooks/module-completion-stop.py` 仅用于触发 `alignment/` Autopilot：每次 Stop 默认后台推进 `NEXT.md` 中 1 个非 `aligned`、非 `blocked` 任务；可用 `CODEX_AUTOPILOT_STEPS` 或 `alignment/autopilot-runs/next-steps` 指定最多 20 个连续任务；必须通过 `codex exec resume --last` 尽量续接当前仓库最近会话，必须加锁、防递归，并把日志写入 `alignment/autopilot-runs/`。
- 不引入 `TODO()`、`fatalError("not implemented")`、`throw NotImplementedError()` 等占位实现。
