#!/usr/bin/env bash
# Manual FFmpeg republish helper (Phoenix normally supervises this).
# Usage: ./scripts/ffmpeg_publish.sh <video_file> <rtmp_url>
set -euo pipefail

VIDEO="${1:?video file required}"
TARGET="${2:?rtmp target required}"
FFMPEG="${FFMPEG_PATH:-ffmpeg}"

exec "$FFMPEG" -hide_banner -loglevel error -re -stream_loop -1 -i "$VIDEO" -c copy -f flv "$TARGET"
