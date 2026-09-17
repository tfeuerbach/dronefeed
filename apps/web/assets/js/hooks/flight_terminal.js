export const FlightTerminal = {
  mounted() {
    this.stickToBottom = true
    this.el.addEventListener("scroll", () => {
      const distance = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
      this.stickToBottom = distance < 48
    })
    this.scrollToEnd()
  },

  updated() {
    if (this.stickToBottom) this.scrollToEnd()
  },

  scrollToEnd() {
    requestAnimationFrame(() => {
      this.el.scrollTop = this.el.scrollHeight
    })
  },
}
