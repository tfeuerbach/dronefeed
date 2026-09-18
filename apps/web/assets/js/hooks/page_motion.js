/**
 * Light page enter/exit motion.
 *
 * IMPORTANT: never leave the page at opacity 0 waiting on nav races.
 * LiveView `navigate` fires page-loading start/stop with kind "redirect", and
 * the replacement main also joins with kind "initial". Those races previously
 * stuck `.df-page-pending { opacity: 0 }` after leaving a live preview.
 */

let exitPromise = Promise.resolve()
/** @type {object | null} */
let active = null

const EXIT_MS = 180
const ENTER_MS = 320

function isNavKind(kind) {
  return kind === "redirect" || kind === "patch"
}

window.addEventListener("phx:page-loading-start", ({ detail }) => {
  if (!isNavKind(detail?.kind)) return
  active?.prepare()
})

window.addEventListener("phx:page-loading-stop", ({ detail }) => {
  if (!isNavKind(detail?.kind) && detail?.kind !== "initial") return
  // Destination page must be visible even if enter animation is skipped.
  Promise.resolve(exitPromise).then(() => {
    queueMicrotask(() => active?.reveal())
  })
})

export const PageMotion = {
  mounted() {
    this._reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    active = this
    // Always visible on mount — never holdPending/opacity 0 across navigations.
    this.reveal()
  },

  updated() {
    // Server HEEX resets class to df-page-pending; keep content visible.
    if (
      this.el.classList.contains("df-page-pending") &&
      !this.el.classList.contains("df-page-exit")
    ) {
      this.reveal()
    }
  },

  destroyed() {
    if (active === this) active = null
    this.finishExit()
    this.clearTimers()
  },

  clearTimers() {
    if (this._raf) cancelAnimationFrame(this._raf)
    this._raf = null
    if (this._animFallback) clearTimeout(this._animFallback)
    this._animFallback = null
    if (this._onEnd) {
      this.el.removeEventListener("animationend", this._onEnd)
      this._onEnd = null
    }
  },

  stripMotionClasses() {
    this.el.classList.remove(
      "df-page-enter",
      "df-page-exit",
      "df-page-shown",
      "df-page-pending"
    )
  },

  finishExit() {
    if (this._resolveExit) {
      const resolve = this._resolveExit
      this._resolveExit = null
      resolve()
    }
  },

  /** Make the page visible. Prefer instant show; light enter is optional. */
  reveal() {
    this.finishExit()
    this.clearTimers()
    this.stripMotionClasses()
    this.el.classList.add("df-page-shown")
  },

  prepare() {
    if (this._reduced) {
      this.stripMotionClasses()
      this.el.classList.add("df-page-shown")
      return
    }

    this.clearTimers()
    this.stripMotionClasses()
    this.el.classList.add("df-page-exit")

    exitPromise = new Promise((resolve) => {
      this._resolveExit = resolve
    })

    const finish = () => {
      // Stay visible during handoff — do not force opacity 0.
      this.stripMotionClasses()
      this.el.classList.add("df-page-shown")
      this.finishExit()
      this.clearTimers()
    }

    this._onEnd = (event) => {
      if (event.target !== this.el || event.animationName !== "df-page-exit") return
      finish()
    }
    this.el.addEventListener("animationend", this._onEnd)
    this._animFallback = window.setTimeout(finish, EXIT_MS + 40)
  },
}
