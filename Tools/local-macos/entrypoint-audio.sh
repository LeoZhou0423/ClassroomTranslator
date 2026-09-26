#!/bin/sh
# Prepare the host microphone source before QEMU opens its ALSA capture
# backend.  Running this from Compose's entrypoint removes the startup race
# that occurs when audio-setup.sh is executed after `docker compose up`.
set -eu

sh /shared/ClassroomTranslator/Tools/local-macos/audio-setup.sh
exec /usr/bin/tini -s /run/entry.sh
