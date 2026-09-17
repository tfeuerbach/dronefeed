export const PasswordReveal = {
  mounted() {
    this.input = this.el.querySelector("input")
    this.button = this.el.querySelector("[data-password-reveal]")
    if (!this.input || !this.button) return

    this.onClick = () => {
      const show = this.input.type === "password"
      this.input.type = show ? "text" : "password"
      this.button.setAttribute("aria-pressed", show ? "true" : "false")
      this.button.setAttribute("aria-label", show ? "Hide password" : "Show password")
      this.button.title = show ? "Hide password" : "Show password"
      this.el.dataset.revealed = show ? "true" : "false"
    }

    this.button.addEventListener("click", this.onClick)
  },

  destroyed() {
    this.button?.removeEventListener("click", this.onClick)
  },
}
