# Sample flight data (gitignored)

Download with:

```bash
./scripts/download_sample_data.sh
```

Enterprise pack is **~5.5 GB**. If you already have the Drive archive:

```bash
QGISFMV_ARCHIVE=/path/to/QGISFMV_Samples.7z ./scripts/download_sample_data.sh
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

[QGISFMV_Samples.7z](https://drive.google.com/file/d/137JaQwx5kVwhdcrxwTCSgxqBbaOjW9be/view)
(All4Gis / QGIS Full Motion Video) — prebuilt MISB ST 0601 MPEG-TS clips with
**embedded KLV** (not consumer SRT). Includes enterprise-style samples such as
`Cheyenne.ts`.

Upload a `.ts` / `.mpg` alone for Public feed; DroneFeed passthroughs the data
track. Prefer these over the old FFmpeg `Day Flight.mpg` (sparse KLV).

Archive is cached under `sample-data/.cache/QGISFMV_Samples.7z` after the first
fetch. Remove `enterprise-klv/.qgis_fmv_extracted` to force re-extract.
