#!/bin/bash
# task-7 阶段 1：launch smoke —— 零新依赖，只用 runner 自带工具。
# 硬门禁：启动成功 / 5s 后进程存活（崩溃=失败）/ TERM 能优雅退出。
# 软断言：窗口名（System Events 无辅助功能授权会报错，仅记录）、截图
# （录屏 TCC 可能拒绝，仅记录）。CI 构建产物无 quarantine，Gatekeeper 不拦；
# 不碰麦克风/语音识别，不会触发 TCC 弹窗。
#
# 用法：bash UITests/launch_smoke.sh [app路径] [证据目录]
set -uo pipefail

APP_SRC="${1:-LingoClass.app}"
APP_DST="/Applications/LingoClass.app"
OUT="${2:-ui-smoke-artifacts}"
mkdir -p "$OUT"
# 日志同时进 stdout（step log）与文件（artifact）。
exec > >(tee "$OUT/launch-smoke.log") 2>&1

echo "=== phase1: launch smoke ==="
echo "src=$APP_SRC dst=$APP_DST out=$OUT"

echo "--- copy to /Applications ---"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST" || { echo "RESULT=FAIL copy"; exit 1; }

echo "--- launch ---"
open "$APP_DST" || { echo "RESULT=FAIL open"; exit 1; }
sleep 5

echo "--- process alive (hard gate: crash = fail) ---"
PIDS="$(pgrep -x LingoClass || true)"
if [ -z "$PIDS" ]; then
  echo "RESULT=FAIL process-dead"
  echo "--- crash reports ---"
  for dir in "$HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports"; do
    [ -d "$dir" ] || continue
    ls -la "$dir" || true
    for f in "$dir"/*.ips; do
      [ -f "$f" ] || continue
      echo "--- $f ---"; head -c 8000 "$f"; echo
    done
  done
  exit 1
fi
echo "RESULT=alive pids=$(echo $PIDS | tr '\n' ' ')"

echo "--- window title (soft: TCC 拒绝仅记录) ---"
if WIN="$(osascript -e 'tell application "System Events" to get name of every window of process "LingoClass"' 2>&1)"; then
  echo "WINDOW_TITLES: $WIN"
else
  echo "SOFT window-title query failed (TCC assistive access 预期内): $WIN"
fi

echo "--- screenshot (soft: 录屏 TCC 可能拒绝) ---"
if screencapture -x "$OUT/launch-smoke.png" 2>"$OUT/screencapture.err"; then
  echo "SCREENSHOT: $OUT/launch-smoke.png"
else
  echo "SOFT screencapture failed: $(cat "$OUT/screencapture.err" 2>/dev/null || true)"
fi

echo "--- graceful exit: TERM + 确认退出 (hard gate) ---"
kill -TERM $PIDS 2>/dev/null || true
DEAD=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! pgrep -x LingoClass >/dev/null 2>&1; then DEAD=1; break; fi
  sleep 1
done
if [ -n "$DEAD" ]; then
  echo "RESULT=PASS exited-gracefully"
else
  echo "RESULT=FAIL term-hung -> SIGKILL"
  pkill -9 -x LingoClass 2>/dev/null || true
  exit 1
fi
