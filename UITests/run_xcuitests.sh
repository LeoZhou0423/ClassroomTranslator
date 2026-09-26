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
# task-12：截图导览 —— 测试进程是沙箱 runner（写工作区 NSCocoaErrorDomain 513，
# run 36236618462）→ 写盘目标 = xctrunner 容器（实证可写；id 源头
# UITests/project.yml:17 + .xctrunner 后缀）。shell 层（无沙箱）在 xcodebuild 后
# 把容器截图 cp 搬运到 $OUT/gui-tour —— 三层闭环：容器写成功 → 搬运成功 →
# workflow 的 Verify 步计数 ≥7。export 保留且同值（若某 Xcode 传了 env 也一致）。
TOUR_CONTAINER_DIR="$HOME/Library/Containers/com.user.lingoclass.uitests.xctrunner/Data/ui-smoke-artifacts/gui-tour"
export LINGOCLASS_TOUR_DIR="$TOUR_CONTAINER_DIR"
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

# 三层闭环第 2 层：容器 → workspace 搬运。两侧 ls 打印；任一失败 exit 非零
# 直接红（Verify 步再做 ≥7 计数 —— 空包/搬运失败都骗不过去）。
echo "--- gui-tour copy: container -> workspace ---"
echo "--- ls container ($TOUR_CONTAINER_DIR) ---"
ls -la "$TOUR_CONTAINER_DIR" || true
if [ ! -d "$TOUR_CONTAINER_DIR" ]; then
  echo "TOUR_COPY_FAILED: container dir missing"
  exit 1
fi
mkdir -p "$OUT/gui-tour"
cp -R "$TOUR_CONTAINER_DIR/." "$OUT/gui-tour/" || { echo "TOUR_COPY_FAILED: cp failed"; exit 1; }
echo "--- ls workspace ($OUT/gui-tour) after copy ---"
ls -la "$OUT/gui-tour" || true

exit $RC
