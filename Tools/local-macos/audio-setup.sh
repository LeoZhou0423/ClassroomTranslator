#!/bin/sh
# LingoClass VM 麦克风桥（容器侧，幂等，可重复执行）。
#
# 原理：Windows 侧通过 docker exec -i 把 PCM 交给 pacat，写入 PulseAudio 的
# null sink。QEMU 从该 sink 的 monitor source 采集。这样采集设备始终可读，
# 避免 ALSA file/FIFO 在 AVAudioEngine 打开麦克风时阻塞或忙等。
set -u

pkill pulseaudio 2>/dev/null || true
rm -rf /run/pulse
mkdir -p /run/pulse
chown pulse:pulse /run/pulse

cat > /tmp/lingoclass-pulse.pa <<'PULSEEOF'
load-module module-native-protocol-unix socket=/run/pulse/native auth-anonymous=1
load-module module-null-sink sink_name=mic_sink rate=48000 channels=1
set-default-source mic_sink.monitor
PULSEEOF

pulseaudio --system --daemonize=yes --disallow-exit --exit-idle-time=-1 \
  -nF /tmp/lingoclass-pulse.pa --log-target=file:/tmp/lingoclass-pulse.log

attempt=0
until pactl --server=unix:/run/pulse/native info >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 50 ] || {
    echo "audio-setup: PulseAudio failed to become ready" >&2
    tail -30 /tmp/lingoclass-pulse.log >&2 || true
    exit 1
  }
  sleep 0.1
done

cat > /etc/asound.conf <<'ALSAEOF'
pcm.mic_capture {
  type pulse
  server "unix:/run/pulse/native"
  device "mic_sink.monitor"
}

pcm.!default {
  type asym
  playback.pcm "null"
  capture.pcm "mic_capture"
}
ALSAEOF

echo "audio-setup: PulseAudio mic source ready"
