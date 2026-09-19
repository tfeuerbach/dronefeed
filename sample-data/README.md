# Sample flight data (gitignored)

Download with:

```bash
./scripts/download_sample_data.sh
```

## consumer-dji/

One flight from [imageomics/KABR-mini-scene-raw-videos](https://huggingface.co/datasets/imageomics/KABR-mini-scene-raw-videos) (CC0):

- `13_01_23-DJI_0030/` — DJI MP4 + `.SRT` telemetry (+ metadata/)

The `.SRT` carries camera settings plus **latitude / longitude / altitude** only (no
ground speed or heading). When Public feed is on, DroneFeed synthesizes MISB KLV
from those GPS cues and derives heading/speed from successive positions. Motion
in this clip is small (~tens of meters), so ops maps may show a near-hover track.

Override flight id: `KABR_FLIGHT=12_01_23-DJI_0008 ./scripts/download_sample_data.sh`

## enterprise-klv/

- `Day_Flight.mpg` — FFmpeg.org STANAG-style MPEG-TS with embedded MISB KLV  
  Source: https://samples.ffmpeg.org/MPEG2/mpegts-klv/

Already includes richer ST 0601 tags (e.g. platform heading and ground speed).
DroneFeed passthroughs the data track on Public feed — good for validating that
tools render motion tags without relying on SRT→KLV derivation.
