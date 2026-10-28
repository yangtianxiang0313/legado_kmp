# Codex 协作规范（本项目）

与用户交流始终使用中文。

@SHARED.md

## 当前仓库范围

本仓库已精简为 KMP shared core + iOS App：

- `shared/src/commonMain/**`：共享核心业务代码
- `shared/src/iosMain/**`：iOS actual / 平台兼容代码
- `shared/src/nativeInterop/**`：iOS native interop
- `iosApp/**`：UIKit iOS 应用工程与 CocoaPods 依赖
- `.codex/hooks/**`：Codex Stop hook 自动推进对齐系统入口

本仓库不再保留测试、迁移工作流文档、AI 迁移资料、回归资源或辅助实验模块。

## 工作规则

- 以 `SHARED.md` 作为项目结构、构建命令和实现约束的最小真相源。
- 阅读页、书架、书源等 Android/Legado 对齐任务必须优先夯实主链路体验细节，不接受“差不多即可”的视觉或交互实现；页眉页脚、正文渲染、安全区避让、菜单 chrome、入口跳转等影响连续使用体验的问题应优先修复。
- 每轮对齐开发应启动多个 agent 并行处理不同模块或文件范围；子 agent 只负责开发实现，不运行测试、不做最终验证；主 agent 统一收口代码、解决冲突、运行格式化/构建/模拟器验证，并在验证通过后提交。
- 文件过大时必须先拆分再继续堆功能：Swift 单个 ViewController 文件超过 800 行、Kotlin/Swift 业务实现文件超过 1200 行时，新增主功能前应优先抽出组件、布局、适配器或 helper，避免继续扩大巨型文件。
- 不恢复已清理的测试/迁移/回归脚手架，除非用户明确要求。
- `.codex/hooks/module-completion-stop.py` 只能承载 `alignment/` Autopilot 自动推进流：每次 Stop 默认后台推进 1 个 `NEXT.md` 任务，可用 `CODEX_AUTOPILOT_STEPS` 或 `alignment/autopilot-runs/next-steps` 指定最多 20 个连续任务；必须通过 `codex exec resume --last` 尽量续接当前仓库最近会话，必须防递归、加锁、保留日志，不承载旧迁移/回归工作流。
- 修改 shared API 或 iOS 调用时，保持 common/iOS 分层清晰，不把平台实现泄漏进 `commonMain`。
