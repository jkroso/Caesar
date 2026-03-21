---
name: captcha
description: Solve captchas (reCAPTCHA v2/v3, hCaptcha, Cloudflare Turnstile) using capsolver.com
---

# Captcha Solver

Automatically detect and solve captchas on the current page. Requires an active browser session.

## Setup

```julia
@use "~/Prosca/skills/captcha.jl"...
```

This imports browser.jl automatically — you don't need to load it separately.
The `capsolver_key` must be set in `~/Prosca/config.yaml`.

## Usage

### Auto-detect and solve

```julia
solve_captcha!(b)
```

Detects the captcha type, sends it to capsolver, and injects the solution token into the page.
After solving, you can submit the form normally.

### Detect only (for debugging)

```julia
detect_captcha(b)
```

Returns a dict with `type`, `sitekey`, and any metadata — or `nothing` if no captcha is found.

## Supported Types

- **reCAPTCHA v2** — checkbox and invisible variants
- **reCAPTCHA v3** — score-based invisible
- **hCaptcha** — checkbox and invisible variants
- **Cloudflare Turnstile** — including action/cdata metadata

## Typical workflow

```julia
@use "~/Prosca/skills/browser.jl"...
@use "~/Prosca/skills/captcha.jl"...
b = Browser()
navigate!(b, "https://example.com/signup")
# fill in form fields...
solve_captcha!(b)
submit!(b, "form")
```

## Tips

- Call `solve_captcha!(b)` right before submitting — tokens expire quickly
- If `detect_captcha(b)` returns `nothing`, the page may load the captcha dynamically — try `wait(b, ".g-recaptcha")` first
- Solving typically takes 5–30 seconds depending on the captcha type
