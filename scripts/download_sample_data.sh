#!/usr/bin/env bash
# Download gitignored demo fixtures into ./sample-data/
#
#   consumer-dji/   — one KABR DJI flight (MP4 + .SRT telemetry), CC0
#   enterprise-klv/ — FFmpeg Day_Flight.mpg (MPEG-TS + in-band MISB KLV)
#
# Requires: python3, curl; installs huggingface_hub if missing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${SAMPLE_DATA_DIR:-$ROOT/sample-data}"
CONSUMER="$OUT/consumer-dji"
ENTERPRISE="$OUT/enterprise-klv"
FLIGHT="${KABR_FLIGHT:-13_01_23-DJI_0030}"
DAY_FLIGHT_URL="${DAY_FLIGHT_URL:-https://samples.ffmpeg.org/MPEG2/mpegts-klv/Day%20Flight.mpg}"

mkdir -p "$CONSUMER" "$ENTERPRISE"

echo "==> Sample data → $OUT"

if ! python3 -c "import huggingface_hub" 2>/dev/null; then
  echo "Installing huggingface_hub (user)…"
  python3 -m pip install --user -q huggingface_hub
fi

echo "==> KABR DJI flight: $FLIGHT (Hugging Face)"
python3 <<PY
from huggingface_hub import snapshot_download

snapshot_download(
    repo_id="imageomics/KABR-mini-scene-raw-videos",
    repo_type="dataset",
    allow_patterns=[
        "${FLIGHT}/${FLIGHT}.MP4",
        "${FLIGHT}/DJI_*.SRT",
        "${FLIGHT}/metadata/*",
    ],
    local_dir="${CONSUMER}",
)
print("KABR download complete → ${CONSUMER}/${FLIGHT}")
PY

echo "==> Enterprise Day_Flight.mpg (FFmpeg samples)"
curl -L --fail --retry 3 --retry-delay 2 \
  -o "$ENTERPRISE/Day_Flight.mpg" \
  "$DAY_FLIGHT_URL"

echo
echo "Done."
echo "  DJI:        $CONSUMER/$FLIGHT/"
echo "  Enterprise: $ENTERPRISE/Day_Flight.mpg"
echo
du -sh "$CONSUMER/$FLIGHT" "$ENTERPRISE/Day_Flight.mpg" 2>/dev/null || true
