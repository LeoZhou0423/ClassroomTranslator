# UITests — task-7 CI 打包产物 GUI 冒烟

用户无 Mac，GUI 验证走 CI（GitHub macOS runner 自带 WindowServer）。两阶段：

## 阶段 1：launch smoke（`UITests/launch_smoke.sh`，硬门禁）

workflow 在 **Create DMG 之后、Upload Artifact 之前** 运行：

1. `.app` 拷到 runner `/Applications`；
2. `open` 启动 → 等 5s → `pgrep` 断言进程存活（**崩溃 = 失败**）；
3. `screencapture` 截图 + `osascript` 取窗口名 —— 两者均为**软断言**（TCC 拒绝只记录不失败）；
4. `TERM` 优雅退出并确认（挂死 = 失败，兜底 SIGKILL）。

证据（日志/截图/崩溃报告）全部 Upload-Artifact（`gui-smoke-evidence`）。
防坑：CI 构建产物无 quarantine → Gatekeeper 不拦；不碰麦克风 → 无 TCC 弹窗。

## 阶段 2：真 UI 断言（`UITests/project.yml` + `run_xcuitests.sh`，尽力）

- 仓库 .gitignore 忽略 `*.xcodeproj` → CI 现场 `brew install xcodegen && xcodegen`；
- 测试用 `XCUIApplication(bundleIdentifier: "com.user.lingoclass")` 启动 /Applications
  里的产物（App 不必在工程内）；
- 断言 5 条：主窗口存在、侧栏可见、Settings 打开、Speech Engine Picker 显示
  Apple SpeechAnalyzer、说话人 Section 存在；**禁用录音流程**（麦克风 TCC 弹窗会卡死）；
- App 默认 UI 是 zh-Hans，脚本先 `defaults write com.user.lingoclass appLanguage en`
  再生成测试（选择器依赖英文文本）。

### 降级规则（任务规格）

`xcodebuild test` 失败原因匹配 **TCC/权限标记**（assistive / accessibility / TCC /
not trusted / screen recording …）→ workflow 放行，保留阶段 1，**不算任务失败**；
其余失败（project.yml schema、断言红、xcodebuild 本体）照常让 run 变红 —— 这是
workflow 改动的自证测试，绿了才算交付。原因与降级记录：本 README + workflow 内注释 +
任务 task-7 描述（收尾时补记）。

## 本地运行（有 Mac 时）

```bash
bash UITests/launch_smoke.sh LingoClass.app        # 阶段 1
bash UITests/run_xcuitests.sh                       # 阶段 2（需 brew xcodegen）
```
