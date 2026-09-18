const HLS_CDN = "https://cdn.jsdelivr.net/npm/hls.js@1.5.17/dist/hls.min.js"

let hlsLoader = null

function loadHls() {
  if (window.Hls) return Promise.resolve(window.Hls)
  if (hlsLoader) return hlsLoader

  hlsLoader = new Promise((resolve, reject) => {
    const script = document.createElement("script")
    script.src = HLS_CDN
    script.async = true
    script.onload = () => (window.Hls ? resolve(window.Hls) : reject(new Error("Hls missing")))
    script.onerror = () => reject(new Error("Failed to load hls.js"))
    document.head.appendChild(script)
  }).catch((err) => {
    hlsLoader = null
    throw err
  })

  return hlsLoader
}

function basicAuthHeader(user, pass) {
  const token = btoa(`${user}:${pass}`)
  return `Basic ${token}`
}

export const LiveHlsPreview = {
  mounted() {
    this.video = this.el.querySelector("video")
    this.status = this.el.querySelector("[data-live-status]")
    this.hls = null
    this.retryTimer = null
    this.edgeTimer = null
    this.destroyed = false
    this.start()
  },

  updated() {
    // phx-update="ignore" — keep player ownership
  },

  destroyed() {
    this.destroyed = true
    this.teardown()
  },

  start() {
    const url = this.el.dataset.hlsUrl
    const user = this.el.dataset.user || "drone"
    const pass = this.el.dataset.pass || ""
    if (!url || !this.video) return

    this.setStatus("Connecting…")

    loadHls()
      .then((Hls) => {
        if (this.destroyed) return

        if (Hls.isSupported()) {
          this.attachHls(Hls, url, user, pass)
        } else if (this.video.canPlayType("application/vnd.apple.mpegurl")) {
          this.attachNative(url, user, pass)
        } else {
          this.setStatus("Live preview needs a modern browser (HLS).")
        }
      })
      .catch(() => {
        if (!this.destroyed) this.setStatus("Could not load video player.")
      })
  },

  attachHls(Hls, url, user, pass) {
    const auth = basicAuthHeader(user, pass)
    // Stay near the live edge. Default hls.js buffering + long phone GOPs
    // easily produce 30–60s delay; YouTube uses LL protocols, not classic HLS.
    this.hls = new Hls({
      enableWorker: true,
      lowLatencyMode: true,
      backBufferLength: 0,
      maxBufferLength: 4,
      maxMaxBufferLength: 8,
      liveSyncDurationCount: 1,
      liveMaxLatencyDurationCount: 4,
      liveDurationInfinity: true,
      maxLiveSyncPlaybackRate: 1.5,
      // MediaMTX HLS uses a cookie-check redirect before serving the playlist.
      xhrSetup: (xhr) => {
        xhr.withCredentials = true
        xhr.setRequestHeader("Authorization", auth)
      },
    })

    this.hls.loadSource(url)
    this.hls.attachMedia(this.video)

    this.hls.on(Hls.Events.MANIFEST_PARSED, () => {
      this.setStatus("")
      this.jumpToLiveEdge()
      this.video.play().catch(() => {})
    })

    this.hls.on(Hls.Events.LEVEL_UPDATED, () => this.jumpToLiveEdge(false))

    this.hls.on(Hls.Events.ERROR, (_event, data) => {
      if (!data.fatal) return

      if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
        this.setStatus("Waiting for publisher…")
        try {
          this.hls.startLoad()
        } catch (_e) {}
        this.scheduleRetry(true)
      } else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
        this.hls.recoverMediaError()
      } else {
        this.setStatus("Live preview error — retrying…")
        this.scheduleRetry(true)
      }
    })

    // Periodic catch-up if we drift (network stalls, long keyframe waits).
    this.edgeTimer = setInterval(() => this.jumpToLiveEdge(false), 4000)
  },

  jumpToLiveEdge(force = true) {
    if (!this.hls || !this.video) return
    const liveSync = this.hls.liveSyncPosition
    if (liveSync == null || !Number.isFinite(liveSync)) return

    const lag = liveSync - this.video.currentTime
    // Jump when far behind; small lag is handled by maxLiveSyncPlaybackRate.
    if (force || lag > 8) {
      this.video.currentTime = liveSync
    }
  },

  attachNative(url, user, pass) {
    const sep = url.includes("?") ? "&" : "?"
    this.video.src = `${url}${sep}user=${encodeURIComponent(user)}&pass=${encodeURIComponent(pass)}`
    this.video.addEventListener(
      "loadedmetadata",
      () => {
        this.setStatus("")
        try {
          if (this.video.seekable && this.video.seekable.length > 0) {
            this.video.currentTime = this.video.seekable.end(this.video.seekable.length - 1)
          }
        } catch (_e) {}
        this.video.play().catch(() => {})
      },
      { once: true }
    )
    this.video.addEventListener("error", () => {
      this.setStatus("Waiting for publisher…")
      this.scheduleRetry(true)
    })
  },

  scheduleRetry(fullRestart = false) {
    if (this.retryTimer || this.destroyed) return
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null
      if (this.destroyed) return
      if (fullRestart) {
        this.teardown()
        this.start()
      }
    }, 4000)
  },

  setStatus(text) {
    if (!this.status) return
    this.status.textContent = text
    this.status.hidden = !text
  },

  teardown() {
    if (this.retryTimer) {
      clearTimeout(this.retryTimer)
      this.retryTimer = null
    }
    if (this.edgeTimer) {
      clearInterval(this.edgeTimer)
      this.edgeTimer = null
    }
    if (this.hls) {
      this.hls.destroy()
      this.hls = null
    }
    if (this.video) {
      this.video.removeAttribute("src")
      this.video.load()
    }
  },
}
