# Sample flight data (gitignored)

Download with:

```bash
./scripts/download_sample_data.sh
```

## consumer-dji/

One flight from [imageomics/KABR-mini-scene-raw-videos](https://huggingface.co/datasets/imageomics/KABR-mini-scene-raw-videos) (CC0):

- `13_01_23-DJI_0030/` — DJI MP4 + `.SRT` telemetry (+ metadata/)

Override flight id: `KABR_FLIGHT=12_01_23-DJI_0008 ./scripts/download_sample_data.sh`

## enterprise-klv/

- `Day_Flight.mpg` — FFmpeg.org STANAG-style MPEG-TS with embedded MISB KLV  
  Source: https://samples.ffmpeg.org/MPEG2/mpegts-klv/
