#!/usr/bin/env bash
# Download gitignored demo fixtures into ./sample-data/
#
#   consumer-dji/   — one KABR DJI flight (MP4 + .SRT telemetry), CC0
#   enterprise-klv/ — QGISFMV_Samples (MISB ST 0601 MPEG-TS + in-band KLV)
#
# Requires: python3, curl; installs huggingface_hub / gdown / py7zr if missing.
# Enterprise archive is ~5.5 GB (Google Drive). Prefer a local copy:
#   QGISFMV_ARCHIVE=/path/to/QGISFMV_Samples.7z ./scripts/download_sample_data.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${SAMPLE_DATA_DIR:-$ROOT/sample-data}"
CONSUMER="$OUT/consumer-dji"
ENTERPRISE="$OUT/enterprise-klv"
CACHE="$OUT/.cache"
FLIGHT="${KABR_FLIGHT:-13_01_23-DJI_0030}"

# QGIS FMV sample pack (All4Gis) — https://drive.google.com/file/d/137JaQwx5kVwhdcrxwTCSgxqBbaOjW9be/view
QGISFMV_DRIVE_ID="${QGISFMV_DRIVE_ID:-137JaQwx5kVwhdcrxwTCSgxqBbaOjW9be}"
QGISFMV_ARCHIVE_NAME="${QGISFMV_ARCHIVE_NAME:-QGISFMV_Samples.7z}"
# Optional: path to an already-downloaded .7z (skips Drive fetch)
QGISFMV_ARCHIVE="${QGISFMV_ARCHIVE:-}"

mkdir -p "$CONSUMER" "$ENTERPRISE" "$CACHE"

echo "==> Sample data → $OUT"

pip_user() {
  python3 -m pip install --user -q "$@"
}

ensure_py() {
  local mod="$1"
  shift
  if ! python3 -c "import $mod" 2>/dev/null; then
    echo "Installing $* (user)…"
    pip_user "$@"
  fi
}

ensure_py huggingface_hub huggingface_hub
ensure_py gdown gdown
ensure_py py7zr py7zr

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

# --- Enterprise: QGISFMV MISB samples -----------------------------------------
ARCHIVE_CACHED="$CACHE/$QGISFMV_ARCHIVE_NAME"
MARKER="$ENTERPRISE/.qgis_fmv_extracted"

if [[ -n "$QGISFMV_ARCHIVE" ]]; then
  if [[ ! -f "$QGISFMV_ARCHIVE" ]]; then
    echo "error: QGISFMV_ARCHIVE not found: $QGISFMV_ARCHIVE" >&2
    exit 1
  fi
  ARCHIVE_SRC="$QGISFMV_ARCHIVE"
  echo "==> Using local QGISFMV archive: $ARCHIVE_SRC"
elif [[ -f "$ARCHIVE_CACHED" ]]; then
  ARCHIVE_SRC="$ARCHIVE_CACHED"
  echo "==> Using cached QGISFMV archive: $ARCHIVE_SRC"
else
  echo "==> QGISFMV_Samples.7z from Google Drive (~5.5 GB)…"
  echo "    (set QGISFMV_ARCHIVE=/path/to/QGISFMV_Samples.7z to skip Drive)"
  python3 -m gdown "$QGISFMV_DRIVE_ID" -O "$ARCHIVE_CACHED" --continue --retries 5
  ARCHIVE_SRC="$ARCHIVE_CACHED"
fi

# Skip extract if marker exists and enterprise dir has media
if [[ -f "$MARKER" ]] && find "$ENTERPRISE" -type f \( -iname '*.ts' -o -iname '*.mpg' -o -iname '*.mpeg4' -o -iname '*.mp4' \) | grep -q .; then
  echo "==> Enterprise samples already extracted (remove $MARKER to re-extract)"
else
  # Drop legacy FFmpeg Day Flight if present
  rm -f "$ENTERPRISE/Day_Flight.mpg"

  echo "==> Extracting QGISFMV samples → $ENTERPRISE"
  python3 <<PY
from pathlib import Path
import py7zr

archive = Path(${ARCHIVE_SRC@Q})
dest = Path(${ENTERPRISE@Q})
dest.mkdir(parents=True, exist_ok=True)

with py7zr.SevenZipFile(archive, mode="r") as z:
  names = z.getnames()
  print(f"Archive members: {len(names)}")
  z.extractall(path=dest)

print(f"Extracted → {dest}")
PY
  date -u +"%Y-%m-%dT%H:%M:%SZ source=$(basename "$ARCHIVE_SRC")" >"$MARKER"
fi

# Cache a copy if we used an external path and cache is empty
if [[ "$ARCHIVE_SRC" != "$ARCHIVE_CACHED" && ! -f "$ARCHIVE_CACHED" ]]; then
  echo "==> Caching archive → $ARCHIVE_CACHED"
  cp -n "$ARCHIVE_SRC" "$ARCHIVE_CACHED" || true
fi

echo
echo "Done."
echo "  DJI:        $CONSUMER/$FLIGHT/"
echo "  Enterprise: $ENTERPRISE/"
echo
du -sh "$CONSUMER/$FLIGHT" "$ENTERPRISE" 2>/dev/null || true
echo
echo "MISB clips under enterprise-klv (upload .ts / .mpg alone — KLV is embedded):"
find "$ENTERPRISE" -type f \( -iname '*.ts' -o -iname '*.mpg' -o -iname '*.mpeg4' \) 2>/dev/null | head -40 || true
