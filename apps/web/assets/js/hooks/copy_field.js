/** One-click copy for capability URLs — avoids trailing newlines from text selection. */
export const CopyField = {
  mounted() {
    this.button = this.el.querySelector("[data-copy-btn]")
    this.input = this.el.querySelector("input, textarea")
    this.onClick = () => this.copy()
    if (this.button) this.button.addEventListener("click", this.onClick)
  },

  destroyed() {
    if (this.button) this.button.removeEventListener("click", this.onClick)
  },

  async copy() {
    const text = (this.el.dataset.copyValue || this.input?.value || "").trim()
    if (!text) return

    try {
      await navigator.clipboard.writeText(text)
      this.flash("Copied")
    } catch (_err) {
      if (this.input) {
        this.input.focus()
        this.input.select()
        this.flash("Select + copy")
      }
    }
  },

  flash(label) {
    if (!this.button) return
    const prev = this.button.textContent
    this.button.textContent = label
    clearTimeout(this._t)
    this._t = setTimeout(() => {
      this.button.textContent = prev
    }, 1200)
  },
}
