#!/bin/bash
# task-7 阶段 2：xcodegen XCUITest —— 真 UI 断言。
# 仓库 .gitignore 忽略 *.xcodeproj → 现场 brew install xcodegen && xcodegen。
# App 不在工程内：用 XCUIApplication(bundleIdentifier:) 启动 /Applications 里
# 的产物（阶段 1 已拷贝并退出）。默认 UI 语言强制英文（文本选择器依赖）。
# 失败分类由 workflow 的下一步完成：TCC/权限类降级放行，其余照常红。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/ui-smoke-artifacts"
mkdir -p "$OUT"
# task-12：截图导览输出目录（ScreenshotTourTests 读同名环境变量；
# App 侧经 launchEnvironment 透传同一约定）。
export LINGOCLASS_TOUR_DIR="$OUT/gui-tour"
mkdir -p "$LINGOCLASS_TOUR_DIR"
exec > >(tee "$OUT/xcuitests.log") 2>&1

echo "=== phase2: xcodegen XCUITest ==="

echo "--- force English UI (app 默认 zh-Hans，选择器依赖英文文本) ---"
defaults write com.user.lingoclass appLanguage -string en
defaults write com.user.lingoclass AppleLanguages -array en

echo "--- brew install xcodegen ---"
if ! brew list --versions xcodegen >/dev/null 2>&1; then
  brew install xcodegen || { echo "BREW_FAILED"; exit 1; }
fi
xcodegen --version || { echo "XCODEGEN_UNUSABLE"; exit 1; }

echo "--- xcodegen generate ---"
cd "$ROOT/UITests" || exit 1
rm -rf LingoclassUITests.xcodeproj
xcodegen generate || { echo "XCODEGEN_FAILED (project.yml schema)"; exit 1; }

echo "--- xcodebuild test ---"
xcodebuild test \
  -project LingoclassUITests.xcodeproj \
  -scheme LingoclassUITests \
  -destination 'platform=macOS' \
  -resultBundlePath "$OUT/UITests.xcresult" \
  -only-testing:LingoclassUITests/LingoclassUITests \
  -only-testing:LingoclassUITests/ScreenshotTourTests
RC=$?
echo "XCODEBUILD_EXIT=$RC"
exit $RC
