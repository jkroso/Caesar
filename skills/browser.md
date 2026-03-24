---
name: browser
description: Control a headless Chrome browser — navigate pages, click, type, read content, manage cookies, take screenshots
---

# Browser Control

You can control a headless Chrome browser to browse the web, interact with web apps, and log into services.

## Setup

```julia
@use "~/Caesar/skills/browser.jl"...
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

## JavaScript shorthand

For executing JavaScript, prefer `{"js": "code"}` over `{"eval": "js(b, \"...\")"}`.
The shorthand avoids nested escaping — just write your JS naturally:

```json
{"js": "document.querySelector('input[name=\"firstName\"]').value = 'Alice'"}
```

The browser variable must be named `b`.

## State-Based Interaction (preferred for complex pages)

Instead of guessing CSS selectors, use `state(b)` to get a numbered list of all interactive elements, then interact by index:

- `index_page(b)` — Returns indexed list of all visible interactive elements on the page
- `interact!(b, index, "click")` — Click element by index
- `interact!(b, index, "type", "hello")` — Type into element by index
- `interact!(b, index, "select", "option_value")` — Select option by index

Or use the shorthand (no Julia needed):
```json
{"index_page": true}
```

**Workflow:** call `index_page(b)` (or `{"state": true}`) to see what's on the page, then `interact!(b, index, action)` to act on it. Re-call `index_page(b)` after page changes since indices reset.

Use CSS selectors (`click!`, `type!`) when you already know the exact selector. Use `index_page(b)` when exploring or on unfamiliar pages.

## Tips

- Use `index_page(b)` to understand a page before interacting — it's more reliable than guessing selectors
- Use `text(b)` to read page content, not screenshots
- Use `{"js": "code"}` for anything the helper functions don't cover (avoids escaping pain)
- Use `wait(b, selector)` after navigation or clicks that trigger page changes
- CSS selectors work like in the browser: `"#id"`, `".class"`, `"button[type=submit]"`, etc.
