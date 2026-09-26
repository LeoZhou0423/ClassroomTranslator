#!/bin/bash
# task-7 缺陷 2 修复：XCUITest 失败分类器（可自测，防假阳性放行）。
#
# 假绿事故（run 36221214297）：旧 grep 含裸 "accessibility"，命中 Xcode 模块
# 缓存文件名 "Accessibility-7ZLS….pcm"（xcodebuild 构建日志必然打印），把
# 编译失败（error: / XCODEBUILD_EXIT=65）误判成 TCC 降级放行。
#
# 用法：
#   classify_xcuitest_failure.sh <日志文件>    # 0=可降级(DEGRADED)  1=必须红
#   classify_xcuitest_failure.sh --self-test  # 内置样例自测（降级步骤每次先跑）
#
# 规则（Lead 四点规格，task-7 描述有回写）：
#   a. 硬失败优先：error: | TEST FAILED | XCODEBUILD_EXIT=[1-9] → 永不可降级；
#   b. TCC 标记收紧（逐词复核不出现在 xcodebuild 构建日志）：
#      assistive access | not authorized | screen.?recording.*(permission|denied)
#      | TCC.*(deny|denied) | not trusted —— 已删除裸 accessibility；
#   c. 只有（无硬失败标记）且（有收紧 TCC 标记）才判可降级，其余一律红；
#   d. --self-test：缺陷日志样例必须判红、纯 TCC 样例必须判可降级。
set -uo pipefail

HARD_RE='error:|TEST FAILED|XCODEBUILD_EXIT=[1-9]'
TCC_RE='assistive access|not authorized|screen.?recording.*(permission|denied)|TCC.*(deny|denied)|not trusted'

classify() {
  local log="$1"
  if grep -Eq "$HARD_RE" "$log"; then
    echo "VERDICT=RED reason=hard-failure (a: error:/TEST FAILED/XCODEBUILD_EXIT)"
    grep -En "$HARD_RE" "$log" | head -n 20
    return 1
  fi
  if grep -Eiq "$TCC_RE" "$log"; then
    echo "VERDICT=DEGRADED reason=tcc-permission (b/c: 收紧 TCC 标记且无硬失败)"
    grep -Ei "$TCC_RE" "$log" | head -n 10
    return 0
  fi
  echo "VERDICT=RED reason=no-marker (c: 无硬失败但也无收紧 TCC 标记)"
  return 1
}

self_test() {
  local tmp rc=0
  tmp="$(mktemp -d)" || { echo "SELFTEST_FAIL mktemp"; return 1; }

  # 样例 1：run 36221214297 假阳性日志关键行（Lead 证据包第 309 行场景）→ 必须红。
  cat > "$tmp/fp-full.log" <<'EOF'
CompileSwift normal arm64 Compiling\ LingoclassUITests.swift
/xcode/DerivedData/ModuleCache.noindex/Accessibility-7ZLS9x8y/Accessibility-7ZLS9x8y.pcm
error: cannot find 'app' in scope
** TEST FAILED **
XCODEBUILD_EXIT=65
EOF
  # 样例 2：仅模块缓存路径（旧分类器正是在这里假阳性）→ 必须红（收紧后不应命中）。
  cat > "$tmp/fp-pcm-only.log" <<'EOF'
CompileC normal arm64 ... /ModuleCache.noindex/Accessibility-7ZLS9x8y.pcm
EOF
  # 样例 3：执行期真 TCC（无任何硬失败标记）→ 必须可降级。
  cat > "$tmp/true-tcc.log" <<'EOF'
osascript is not allowed to send keystrokes / get window names without
assistive access. XCUITest runner could not query the window tree.
XCODEBUILD_EXIT=0-note: no hard markers in this fixture
EOF
  # 样例 4：无标记的未知失败 → 必须红（fail-closed）。
  : > "$tmp/no-marker.log"

  run_expect() { # <log> <want: RED|DEGRADED> <label>
    local out verdict
    out="$(classify "$1" 2>&1)"
    verdict="$(echo "$out" | sed -n 's/^VERDICT=\([A-Z]*\).*/\1/p' | head -n1)"
    if [ "$verdict" = "$2" ]; then
      echo "SELFTEST_PASS $3 ($verdict)"
    else
      echo "SELFTEST_FAIL $3 want=$2 got=$verdict"; echo "$out"; rc=1
    fi
  }
  run_expect "$tmp/fp-full.log"      RED      "缺陷样例: 假阳性日志含 error:/EXIT=65"
  run_expect "$tmp/fp-pcm-only.log"  RED      "缺陷样例: 裸 accessibility 模块缓存路径不再放行"
  run_expect "$tmp/true-tcc.log"     DEGRADED "真 TCC: 收紧标记命中且无硬失败"
  run_expect "$tmp/no-marker.log"    RED      "未知失败 fail-closed"
  rm -rf "$tmp"
  return $rc
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi
if [ $# -lt 1 ] || [ ! -f "$1" ]; then
  echo "usage: $0 <xcuitest.log> | --self-test"
  exit 1
fi
classify "$1"
