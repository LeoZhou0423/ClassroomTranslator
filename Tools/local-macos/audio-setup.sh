#!/bin/sh
# LingoClass VM 麦克风桥（容器侧，幂等，可重复执行）。
#
# 原理：ALSA file 插件把 QEMU 的采集 PCM 接到 /run/mic.fifo；nc 监听 19999
# 把 Windows 侧 mic-bridge.ps1 推来的原始 PCM (s16le/48k/单声道) 写进 fifo。
# 连接间隙灌 1 秒静音，保证 QEMU 采集端永不停顿（fifo 写端常开，无 EOF）。
set -u

cat > /etc/asound.conf <<'ALSAEOF'
# Raw PCM supplied by the Windows ffmpeg bridge.  The file plugin's `infile`
# property is the capture source; `file` is only for playback/output.
pcm.!default {
  type file
  slave.pcm "null"
  file "/dev/null"
  infile "/run/mic.fifo"
  format "raw"
}
ALSAEOF

mkdir -p /run
[ -p /run/mic.fifo ] || mkfifo /run/mic.fifo

if ! ps ax 2>/dev/null | grep -q '[n]c -l 19999'; then
  nohup sh -c 'while true; do nc -l 19999; dd if=/dev/zero bs=1920 count=50 2>/dev/null; done | dd of=/run/mic.fifo bs=4096 2>/dev/null'     >/tmp/mic-bridge.log 2>&1 &
fi

echo "audio-setup: asound.conf + fifo + nc listener ready"
