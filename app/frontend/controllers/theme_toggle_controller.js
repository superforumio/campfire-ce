import { Controller } from "@hotwired/stimulus"

// Source - https://stackoverflow.com/a/75124760
// Posted by Mendhak, modified by community. License - CC BY-SA 4.0
// Adapted for Stimulus controller

// Toggles between light/dark theme by manipulating stylesheet media queries
// This approach overrides prefers-color-scheme without needing CSS changes
export default class extends Controller {
  static targets = ["label"]

  connect() {
    this.applyPreferredColorScheme(this.getPreferredColorScheme())
    this.updateLabel()
  }

  toggle() {
    const newScheme = this.getPreferredColorScheme() === "light" ? "dark" : "light"
    this.applyPreferredColorScheme(newScheme)
    this.savePreferredColorScheme(newScheme)
    this.updateLabel()
  }

  // Return the system level color scheme, but if something's in local storage, return that
  // Unless the system scheme matches the stored scheme, in which case remove from local storage
  getPreferredColorScheme() {
    const systemScheme = window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
    let chosenScheme = systemScheme

    if (localStorage.getItem("scheme")) {
      chosenScheme = localStorage.getItem("scheme")
    }

    if (systemScheme === chosenScheme) {
      localStorage.removeItem("scheme")
    }

    return chosenScheme
  }

  // Write chosen color scheme to local storage
  // Unless the system scheme matches the stored scheme, in which case remove from local storage
  savePreferredColorScheme(scheme) {
    const systemScheme = window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"

    if (systemScheme === scheme) {
      localStorage.removeItem("scheme")
    } else {
      localStorage.setItem("scheme", scheme)
    }
  }

  // Apply the chosen color scheme by traversing stylesheet rules and modifying media queries
  applyPreferredColorScheme(scheme) {
    for (let s = 0; s < document.styleSheets.length; s++) {
      try {
        const styleSheet = document.styleSheets[s]
        if (!styleSheet.cssRules) continue

        for (let i = 0; i < styleSheet.cssRules.length; i++) {
          const rule = styleSheet.cssRules[i]

          if (rule && rule.media && rule.media.mediaText.includes("prefers-color-scheme")) {
            switch (scheme) {
              case "light":
                rule.media.appendMedium("original-prefers-color-scheme")
                if (rule.media.mediaText.includes("light")) rule.media.deleteMedium("(prefers-color-scheme: light)")
                if (rule.media.mediaText.includes("dark")) rule.media.deleteMedium("(prefers-color-scheme: dark)")
                break
              case "dark":
                rule.media.appendMedium("(prefers-color-scheme: light)")
                rule.media.appendMedium("(prefers-color-scheme: dark)")
                if (rule.media.mediaText.includes("original")) rule.media.deleteMedium("original-prefers-color-scheme")
                break
              default:
                rule.media.appendMedium("(prefers-color-scheme: dark)")
                if (rule.media.mediaText.includes("light")) rule.media.deleteMedium("(prefers-color-scheme: light)")
                if (rule.media.mediaText.includes("original")) rule.media.deleteMedium("original-prefers-color-scheme")
                break
            }
          }
        }
      } catch (e) {
        // Skip stylesheets we can't access (e.g., cross-origin)
      }
    }
  }

  updateLabel() {
    if (!this.hasLabelTarget) return
    const scheme = this.getPreferredColorScheme()
    this.labelTarget.textContent = scheme === "dark" ? "Dark" : "Light"
  }
}
