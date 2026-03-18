---
name: browser
description: Control a headless Chrome browser — navigate pages, click, type, read content, manage cookies, take screenshots
---

# Browser Control

You can control a headless Chrome browser to browse the web, interact with web apps, and log into services.

## Setup

```julia
Base.include(@__MODULE__, expanduser("~/Prosca/skills/browser.jl"))
b = Browser()
```

Call `close(b)` when you're done browsing.

## API

All methods take a `Browser` as the first argument.

### Navigation
- `navigate!(b, url)` — Go to a URL and wait for page load
- `b.url` — Get current page URL
- `b.title` — Get current page title

### Reading Content
- `text(b, selector="body")` — Get text content of an element
- `html(b, selector="body")` — Get innerHTML of an element
- `js(b, code)` — Execute arbitrary JavaScript and return result

### Interaction
- `click!(b, selector)` — Click an element by CSS selector
- `type!(b, selector, text)` — Type text into an input field
- `submit!(b, selector)` — Submit a form or click a submit button
- `wait(b, selector; timeout=10)` — Wait for an element to appear

### Screenshots
- `screenshot(b)` — Capture page screenshot, returns path to PNG file
- `screenshot(b; path="/tmp/shot.png")` — Save to specific path

### Cookies
- `cookies(b)` — List all cookies
- `cookies(b; url="https://example.com")` — List cookies for a URL
- `set_cookie!(b; name="x", value="y", domain=".example.com")` — Set a cookie
- `clear_cookies!(b)` — Clear all cookies

Cookies persist across sessions automatically via Chrome's user data directory.

### Low-level
- `cdp(b, method, params)` — Send a raw CDP command

## Tips

- Use `text(b)` to read page content, not screenshots
- Use `js(b, code)` for anything the helper functions don't cover
- Use `wait(b, selector)` after navigation or clicks that trigger page changes
- CSS selectors work like in the browser: `"#id"`, `".class"`, `"button[type=submit]"`, etc.
