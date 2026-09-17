const MAX = 8

function normalize(s) {
  return (s || "").trim().toLowerCase()
}

function filterPlaces(places, query) {
  const q = normalize(query)
  if (q.length < 1) return []

  const starts = []
  const includes = []

  for (const place of places) {
    const n = normalize(place)
    if (n.startsWith(q) || n.split(/[,\s]+/).some((w) => w.startsWith(q))) {
      starts.push(place)
    } else if (n.includes(q)) {
      includes.push(place)
    }
    if (starts.length >= MAX) break
  }

  return starts.concat(includes).slice(0, MAX)
}

export const LocationSuggest = {
  mounted() {
    this.input = this.el.querySelector("[data-location-input]")
    this.list = this.el.querySelector("[data-location-list]")
    this.places = []

    try {
      this.places = JSON.parse(this.el.dataset.places || "[]")
    } catch (_e) {
      this.places = []
    }

    this.activeIndex = -1
    this.open = false

    this.onInput = () => this.render(this.input.value)
    this.onFocus = () => this.render(this.input.value)
    this.onBlur = () => {
      // Delay so option mousedown can fire first
      window.setTimeout(() => this.close(), 150)
    }
    this.onKeyDown = (e) => this.handleKey(e)
    this.onDocPointer = (e) => {
      if (!this.el.contains(e.target)) this.close()
    }

    this.input.addEventListener("input", this.onInput)
    this.input.addEventListener("focus", this.onFocus)
    this.input.addEventListener("blur", this.onBlur)
    this.input.addEventListener("keydown", this.onKeyDown)
    document.addEventListener("pointerdown", this.onDocPointer)
  },

  destroyed() {
    this.input?.removeEventListener("input", this.onInput)
    this.input?.removeEventListener("focus", this.onFocus)
    this.input?.removeEventListener("blur", this.onBlur)
    this.input?.removeEventListener("keydown", this.onKeyDown)
    document.removeEventListener("pointerdown", this.onDocPointer)
  },

  render(query) {
    if (!this.list || !this.input) return

    const matches = filterPlaces(this.places, query)
    this.activeIndex = matches.length ? 0 : -1
    this.list.replaceChildren()

    if (!matches.length) {
      this.close()
      return
    }

    const frag = document.createDocumentFragment()
    for (const [i, place] of matches.entries()) {
      const li = document.createElement("li")
      li.role = "option"
      li.id = `${this.input.id}-opt-${i}`
      li.className = "df-location-option"
      li.textContent = place
      li.dataset.value = place
      if (i === this.activeIndex) {
        li.classList.add("df-location-option--active")
        li.setAttribute("aria-selected", "true")
      }
      li.addEventListener("mousedown", (e) => {
        e.preventDefault()
        this.choose(place)
      })
      frag.appendChild(li)
    }

    this.list.appendChild(frag)
    this.list.hidden = false
    this.open = true
    this.el.classList.add("df-location-wrap--open")
    this.input.setAttribute("aria-expanded", "true")
    this.syncActiveDescendant()
  },

  handleKey(e) {
    if (!this.open) {
      if (e.key === "ArrowDown") {
        this.render(this.input.value)
        e.preventDefault()
      }
      return
    }

    const options = [...this.list.querySelectorAll("[data-value]")]
    if (!options.length) return

    if (e.key === "ArrowDown") {
      e.preventDefault()
      this.activeIndex = (this.activeIndex + 1) % options.length
      this.paintActive(options)
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      this.activeIndex = (this.activeIndex - 1 + options.length) % options.length
      this.paintActive(options)
    } else if (e.key === "Enter" && this.activeIndex >= 0) {
      e.preventDefault()
      this.choose(options[this.activeIndex].dataset.value)
    } else if (e.key === "Escape") {
      e.preventDefault()
      this.close()
    }
  },

  paintActive(options) {
    options.forEach((el, i) => {
      const on = i === this.activeIndex
      el.classList.toggle("df-location-option--active", on)
      el.setAttribute("aria-selected", on ? "true" : "false")
    })
    this.syncActiveDescendant()
  },

  syncActiveDescendant() {
    if (this.activeIndex < 0) {
      this.input.removeAttribute("aria-activedescendant")
      return
    }
    this.input.setAttribute("aria-activedescendant", `${this.input.id}-opt-${this.activeIndex}`)
  },

  choose(value) {
    this.input.value = value
    // Notify LiveView without relying on a synthetic "input" that races remounts
    this.input.dispatchEvent(new Event("change", {bubbles: true}))
    this.close()
    this.input.focus()
  },

  close() {
    if (!this.list) return
    this.list.hidden = true
    this.list.replaceChildren()
    this.open = false
    this.activeIndex = -1
    this.el.classList.remove("df-location-wrap--open")
    this.input?.setAttribute("aria-expanded", "false")
    this.input?.removeAttribute("aria-activedescendant")
  },
}
