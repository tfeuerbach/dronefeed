
let inFlight = false
let revealToken = 0
let exitPromise = Promise.resolve()
/** @type {object | null} */
let active = null

const EXIT_MS = 200
const ENTER_MS = 380

function isNavKind(kind) {
  return kind === "redirect" || kind === "patch"
}

function queueReveal() {
  const token = ++revealToken
  Promise.resolve(exitPromise).then(() => {
    queueMicrotask(() => {
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          if (token !== revealToken) return
          inFlight = false
          active?.enter()
        })
      })
    })
  })
}

window.addEventListener("phx:page-loading-start", ({ detail }) => {
  if (!isNavKind(detail?.kind)) return
  inFlight = true
  revealToken++
  active?.prepare()
})

window.addEventListener("phx:page-loading-stop", ({ detail }) => {
  if (!isNavKind(detail?.kind)) return
  queueReveal()
})

export const PageMotion = {
  mounted() {
    this._reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    this._phase = "pending"
    active = this

    if (this._reduced) {
      this.show()
      return
    }

    if (inFlight) {
      this.holdPending()
    } else {
      this.enter()
    }

    this._failsafe = window.setTimeout(() => {
      if (this._phase === "pending" || this._phase === "enter" || this._phase === "exit") {
        this.show()
      }
    }, EXIT_MS + ENTER_MS + 250)
  },

  updated() {
    this.restore()
  },

  destroyed() {
    if (active === this) active = null
    this.finishExit()
    this.clearTimers()
  },

  clearTimers() {
    if (this._raf) cancelAnimationFrame(this._raf)
    this._raf = null
    if (this._failsafe) clearTimeout(this._failsafe)
    this._failsafe = null
    this.clearAnimOnly()
  },

  clearAnimOnly() {
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

  holdPending() {
    this._phase = "pending"
    this.clearAnimOnly()
    this.stripMotionClasses()
    this.el.classList.add("df-page-pending")
  },

  finishExit() {
    if (this._resolveExit) {
      const resolve = this._resolveExit
      this._resolveExit = null
      resolve()
    }
  },

  restore() {
    if (this._phase === "exit") {
      if (this.el.classList.contains("df-page-exit")) return
      this.stripMotionClasses()
      this.el.classList.add("df-page-exit")
      return
    }

    if (this._phase === "pending" || inFlight) {
      if (this.el.classList.contains("df-page-pending")) return
      this.stripMotionClasses()
      this.el.classList.add("df-page-pending")
      return
    }

    if (this._phase === "enter") {
      if (this.el.classList.contains("df-page-enter")) return
      this.stripMotionClasses()
      this.el.classList.add("df-page-enter")
      return
    }

    if (!this.el.classList.contains("df-page-shown")) {
      this.stripMotionClasses()
      this.el.classList.add("df-page-shown")
    }
  },

  prepare() {
    if (this._phase === "pending" || this._phase === "exit") {
      this.holdPending()
      return
    }

    if (this._reduced) {
      this.holdPending()
      return
    }

    this._phase = "exit"
    this.clearAnimOnly()
    this.stripMotionClasses()
    this.el.classList.add("df-page-exit")

    exitPromise = new Promise((resolve) => {
      this._resolveExit = resolve
    })

    const finish = () => {
      if (this._phase !== "exit") return
      this.holdPending()
      this.finishExit()
    }

    this._onEnd = (event) => {
      if (event.target !== this.el || event.animationName !== "df-page-exit") return
      finish()
    }

    this.el.addEventListener("animationend", this._onEnd)
    this._animFallback = window.setTimeout(finish, EXIT_MS + 40)
  },

  show() {
    this._phase = "shown"
    inFlight = false
    this.finishExit()
    this.clearAnimOnly()
    this.stripMotionClasses()
    this.el.classList.add("df-page-shown")
  },

  enter() {
    if (this._reduced) {
      this.show()
      return
    }

    if (this._phase === "enter" || this._phase === "shown") return

    if (this._phase === "exit") {
      this.holdPending()
      this.finishExit()
    }

    this._phase = "pending"
    this.clearAnimOnly()
    this.stripMotionClasses()
    this.el.classList.add("df-page-pending")

    this._raf = requestAnimationFrame(() => {
      this._raf = requestAnimationFrame(() => {
        this._phase = "enter"
        this.el.classList.remove("df-page-pending")
        this.el.classList.add("df-page-enter")

        const finish = () => {
          if (this._phase !== "enter") return
          this._phase = "shown"
          this.el.classList.add("df-page-shown")
          this.el.classList.remove("df-page-enter")
          if (this._onEnd) {
            this.el.removeEventListener("animationend", this._onEnd)
            this._onEnd = null
          }
          if (this._animFallback) {
            clearTimeout(this._animFallback)
            this._animFallback = null
          }
        }

        this._onEnd = (event) => {
          if (event.target !== this.el || event.animationName !== "df-page-enter") return
          finish()
        }

        this.el.addEventListener("animationend", this._onEnd)
        this._animFallback = window.setTimeout(finish, ENTER_MS + 40)
      })
    })
  },
}
