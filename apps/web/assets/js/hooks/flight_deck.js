const LEAFLET_CSS = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"
const LEAFLET_JS = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"

function loadLeaflet() {
  if (window.L) return Promise.resolve(window.L)

  if (!document.querySelector(`link[href="${LEAFLET_CSS}"]`)) {
    const link = document.createElement("link")
    link.rel = "stylesheet"
    link.href = LEAFLET_CSS
    document.head.appendChild(link)
  }

  if (window.__leafletLoading) return window.__leafletLoading

  window.__leafletLoading = new Promise((resolve, reject) => {
    const script = document.createElement("script")
    script.src = LEAFLET_JS
    script.onload = () => resolve(window.L)
    script.onerror = reject
    document.head.appendChild(script)
  })

  return window.__leafletLoading
}

function parsePoints(el) {
  try {
    const raw = el.dataset.points || "[]"
    const data = JSON.parse(raw)
    return Array.isArray(data) ? data : []
  } catch (_e) {
    return []
  }
}

function findPoint(points, tMs) {
  if (!points.length) return null
  let lo = 0
  let hi = points.length - 1
  while (lo < hi) {
    const mid = (lo + hi) >> 1
    if (points[mid].t_ms < tMs) lo = mid + 1
    else hi = mid
  }
  const i = lo
  if (i === 0) return points[0]
  const prev = points[i - 1]
  const cur = points[i]
  return Math.abs(cur.t_ms - tMs) < Math.abs(prev.t_ms - tMs) ? cur : prev
}

function fmtCoord(v) {
  if (v == null || Number.isNaN(v)) return "—"
  return Number(v).toFixed(6)
}

function fmtAlt(v) {
  if (v == null || Number.isNaN(v)) return "—"
  return `${Number(v).toFixed(1)} m`
}

export const FlightDeck = {
  mounted() {
    this.points = parsePoints(this.el)
    this.map = null
    this.marker = null
    this.trail = null
    this.resizeObserver = null
    this.video = this.el.querySelector("video")
    this.onTime = () => this.syncFromVideo()

    if (this.video) {
      this.video.addEventListener("timeupdate", this.onTime)
      this.video.addEventListener("seeked", this.onTime)
    }

    if (this.points.length) {
      loadLeaflet()
        .then((L) => this.initMap(L))
        .catch(() => {})
      this.applyPoint(this.points[0])
    }
  },

  updated() {
    this.points = parsePoints(this.el)
    if (this.map) {
      requestAnimationFrame(() => this.map.invalidateSize())
    }
  },

  destroyed() {
    if (this.video) {
      this.video.removeEventListener("timeupdate", this.onTime)
      this.video.removeEventListener("seeked", this.onTime)
    }
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
      this.resizeObserver = null
    }
    if (this.map) {
      this.map.remove()
      this.map = null
    }
  },

  initMap(L) {
    const root = this.el.querySelector("[data-map-root]")
    if (!root || this.map) return

    const start = this.points[0]
    this.map = L.map(root, { zoomControl: true, attributionControl: true }).setView(
      [start.lat, start.lon],
      15
    )

    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
    }).addTo(this.map)

    const latlngs = this.points.map((p) => [p.lat, p.lon])
    this.trail = L.polyline(latlngs, {
      color: "#2a9d8f",
      weight: 3,
      opacity: 0.85,
    }).addTo(this.map)

    this.marker = L.circleMarker([start.lat, start.lon], {
      radius: 7,
      color: "#0f766e",
      fillColor: "#14b8a6",
      fillOpacity: 0.95,
      weight: 2,
    }).addTo(this.map)

    this.map.fitBounds(this.trail.getBounds(), { padding: [24, 24] })

    // Leaflet needs a size recalc after flex/grid layout settles
    requestAnimationFrame(() => this.map.invalidateSize())
    this.resizeObserver = new ResizeObserver(() => {
      if (this.map) this.map.invalidateSize({ animate: false })
    })
    this.resizeObserver.observe(root)
  },

  syncFromVideo() {
    if (!this.video || !this.points.length) return
    const tMs = Math.floor(this.video.currentTime * 1000)
    const point = findPoint(this.points, tMs)
    if (point) this.applyPoint(point)
  },

  applyPoint(point) {
    const latEl = this.el.querySelector('[data-gauge="lat"]')
    const lonEl = this.el.querySelector('[data-gauge="lon"]')
    const altEl = this.el.querySelector('[data-gauge="alt"]')
    const rawEl = this.el.querySelector("[data-raw-line]")

    if (latEl) latEl.textContent = fmtCoord(point.lat)
    if (lonEl) lonEl.textContent = fmtCoord(point.lon)
    if (altEl) altEl.textContent = fmtAlt(point.alt)
    if (rawEl && point.raw) rawEl.textContent = point.raw

    if (this.marker) {
      this.marker.setLatLng([point.lat, point.lon])
    }
  },
}
