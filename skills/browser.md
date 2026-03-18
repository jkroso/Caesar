---
name: browser
description: Control a headless Chrome browser — navigate pages, click, type, read content, manage cookies, take screenshots
---

# Browser Control

You can control a headless Chrome browser to browse the web, interact with web apps, and log into services.

## Setup

Load the browser module into your REPL before using any browser functions:

```julia
@use "~/Prosca/skills/browser.jl"...
browser_open()
```

Call `browser_close()` when you're done browsing.

## Available Functions

### Navigation
- `browser_navigate(url)` — Go to a URL and wait for page load
- `browser_url()` — Get current page URL
- `browser_title()` — Get current page title

### Reading Content
- `browser_text(selector="body")` — Get text content of an element
- `browser_html(selector="body")` — Get innerHTML of an element
- `browser_eval(js)` — Execute arbitrary JavaScript and return result

### Interaction
- `browser_click(selector)` — Click an element by CSS selector
- `browser_type(selector, text)` — Type text into an input field
- `browser_submit(selector)` — Submit a form or click a submit button
- `browser_wait(selector; timeout=10)` — Wait for an element to appear

### Screenshots
- `browser_screenshot()` — Capture page screenshot, returns path to PNG file
- `browser_screenshot(path="/tmp/shot.png")` — Save to specific path

### Cookies
- `browser_cookies()` — List all cookies
- `browser_cookies(url="https://example.com")` — List cookies for a URL
- `browser_set_cookie(name="x", value="y", domain=".example.com")` — Set a cookie
- `browser_clear_cookies()` — Clear all cookies

Cookies persist across sessions automatically via Chrome's user data directory.

## Tips

- Use `browser_text()` to read page content, not screenshots
- Use `browser_eval(js)` for anything the helper functions don't cover
- Use `browser_wait(selector)` after navigation or clicks that trigger page changes
- CSS selectors work like in the browser: `"#id"`, `".class"`, `"button[type=submit]"`, etc.
