import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/drone_feed"
import topbar from "../vendor/topbar"
import {FlightDeck} from "./hooks/flight_deck"
import {FlightTerminal} from "./hooks/flight_terminal"
import {LocationSuggest} from "./hooks/location_suggest"
import {PasswordReveal} from "./hooks/password_reveal"
import {LiveHlsPreview} from "./hooks/live_hls_preview"
import {CopyField} from "./hooks/copy_field"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    FlightDeck,
    FlightTerminal,
    LocationSuggest,
    PasswordReveal,
    LiveHlsPreview,
    CopyField,
  },
})

topbar.config({
  barColors: {0: "#0D9F8F", ".5": "#14B8A6", "1.0": "#0D9F8F"},
  shadowColor: "rgba(15, 20, 25, .28)",
  barThickness: 4,
  className: "df-topbar",
})
window.addEventListener("phx:page-loading-start", _info => topbar.show(200))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()
window.liveSocket = liveSocket

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()

    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
