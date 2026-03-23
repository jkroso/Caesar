# browser.jl — Chrome DevTools Protocol client for browser automation
#
# Launches headless Chrome and controls it via CDP over WebSocket.
# Cookie state persists across sessions via a dedicated user-data-dir.

@use HTTP
@use JSON3
@use Base64
@use "github.com/jkroso/Prospects.jl" @property

const CHROME_PATH = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const DATA_DIR = joinpath(homedir(), "Prosca", "browser-data")

# ── Browser ──────────────────────────────────────────────────────────

mutable struct Browser
  process::Base.Process
  send_ch::Channel{Tuple{String, Channel}}
  msg_id::Int
  running::Bool
end

function Browser(; port::Int=9222)
  mkpath(DATA_DIR)

  proc = run(Cmd([CHROME_PATH,
    "--headless=new",
    "--remote-debugging-port=$port",
    "--user-data-dir=$DATA_DIR",
    "--no-first-run",
    "--disable-gpu",
    "--disable-extensions"]); wait=false)

  # Wait for Chrome to be ready and get a page target
  ws_url = nothing
  for _ in 1:30
    try
      resp = HTTP.get("http://localhost:$port/json"; retry=false, connect_timeout=1, readtimeout=2)
      targets = JSON3.read(String(resp.body))
      for t in targets
        if get(t, :type, "") == "page"
          ws_url = string(t[:webSocketDebuggerUrl])
          break
        end
      end
      if ws_url === nothing
        HTTP.get("http://localhost:$port/json/new"; retry=false, readtimeout=2)
        continue
      end
      break
    catch
      sleep(0.5)
    end
  end
  ws_url === nothing && (kill(proc); error("Chrome failed to start"))

  send_ch = Channel{Tuple{String, Channel}}(32)
  ready_ch = Channel{Nothing}(1)
  b = Browser(proc, send_ch, 0, true)

  @async begin
    try
      HTTP.WebSockets.open(ws_url) do ws
        responses = Dict{Int, Channel}()

        @async begin
          try
            while b.running
              data = HTTP.WebSockets.receive(ws)
              msg = JSON3.read(String(data))
              if msg isa AbstractDict && haskey(msg, :id)
                ch = get(responses, msg[:id], nothing)
                ch !== nothing && put!(ch, msg)
              end
            end
          catch
            b.running = false
          end
        end

        put!(ready_ch, nothing)

        for (json_msg, resp_ch) in send_ch
          b.running || break
          parsed = JSON3.read(json_msg)
          responses[parsed[:id]] = resp_ch
          HTTP.WebSockets.send(ws, json_msg)
        end
      end
    catch
      b.running = false
      isopen(ready_ch) && put!(ready_ch, nothing)
    end
  end

  take!(ready_ch)

  cdp(b, "Page.enable")
  cdp(b, "Runtime.enable")
  cdp(b, "Network.enable")
  b
end

function Base.close(b::Browser)
  b.running = false
  close(b.send_ch)
  try
    pid = getpid(b.process)
    run(`pkill -P $pid`; wait=false)
    kill(b.process)
  catch end
  nothing
end

# ── CDP transport ────────────────────────────────────────────────────

function cdp(b::Browser, method::String, params::Dict{String,Any}=Dict{String,Any}(); timeout::Int=30)
  b.running || error("Browser session is closed")
  b.msg_id += 1
  id = b.msg_id
  resp_ch = Channel{Any}(1)
  msg = JSON3.write(Dict("id" => id, "method" => method, "params" => params))
  put!(b.send_ch, (msg, resp_ch))

  result = timedwait(() -> isready(resp_ch), float(timeout))
  result == :timed_out && error("CDP command timed out: $method")

  resp = take!(resp_ch)
  if resp isa AbstractDict && haskey(resp, :error)
    error("CDP error: $(JSON3.write(resp[:error]))")
  end
  get(resp, :result, nothing)
end

# ── Navigation ───────────────────────────────────────────────────────

function navigate!(b::Browser, url::String)
  cdp(b, "Page.navigate", Dict{String,Any}("url" => url))
  sleep(1)
  cdp(b, "Runtime.evaluate", Dict{String,Any}(
    "expression" => "document.readyState",
    "returnByValue" => true
  ))
  "Navigated to $url"
end

# ── DOM interaction ──────────────────────────────────────────────────

function click!(b::Browser, selector::String)
  js(b, """
    const el = document.querySelector($(JSON3.write(selector)));
    if (!el) throw new Error('Element not found: $(escape_string(selector))');
    el.click();
    'clicked'
  """)
end

function type!(b::Browser, selector::String, text::String)
  js(b, """
    const el = document.querySelector($(JSON3.write(selector)));
    if (!el) throw new Error('Element not found: $(escape_string(selector))');
    el.focus();
    el.value = $(JSON3.write(text));
    el.dispatchEvent(new Event('input', {bubbles: true}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
    'typed'
  """)
end

function submit!(b::Browser, selector::String)
  js(b, """
    const el = document.querySelector($(JSON3.write(selector)));
    if (!el) throw new Error('Element not found: $(escape_string(selector))');
    const form = el.closest('form') || el;
    if (form.submit) { form.submit(); 'submitted' }
    else { el.click(); 'clicked' }
  """)
end

# ── Reading ──────────────────────────────────────────────────────────

function text(b::Browser, selector::String="body")
  js(b, """
    const el = document.querySelector($(JSON3.write(selector)));
    el ? el.innerText : ''
  """)
end

function html(b::Browser, selector::String="body")
  js(b, """
    const el = document.querySelector($(JSON3.write(selector)));
    el ? el.innerHTML : ''
  """)
end

@property Browser.url = js(self, "window.location.href")
@property Browser.title = js(self, "document.title")

# ── JavaScript ───────────────────────────────────────────────────────

function js(b::Browser, expression::String)
  result = cdp(b, "Runtime.evaluate", Dict{String,Any}(
    "expression" => expression,
    "returnByValue" => true,
    "awaitPromise" => true
  ))
  result === nothing && return nothing
  exc = get(result, :exceptionDetails, nothing)
  if exc !== nothing
    text = try get(exc[:exception], :description, string(exc)) catch; string(exc) end
    error("JS error: $text")
  end
  val = get(result, :result, nothing)
  val === nothing && return nothing
  get(val, :value, nothing)
end

# ── Screenshot ───────────────────────────────────────────────────────

function screenshot(b::Browser; path::Union{String,Nothing}=nothing)
  result = cdp(b, "Page.captureScreenshot", Dict{String,Any}("format" => "png"))
  data = Base64.base64decode(result[:data])
  out = path !== nothing ? path : tempname() * ".png"
  write(out, data)
  out
end

# ── Wait ─────────────────────────────────────────────────────────────

function wait(b::Browser, selector::String; timeout::Int=10)
  deadline = time() + timeout
  while time() < deadline
    found = js(b, """document.querySelector($(JSON3.write(selector))) !== null""")
    found === true && return true
    sleep(0.3)
  end
  error("Timeout waiting for element: $selector")
end

# ── Cookies ──────────────────────────────────────────────────────────

function cookies(b::Browser; url::Union{String,Nothing}=nothing)
  params = Dict{String,Any}()
  url !== nothing && (params["urls"] = [url])
  result = cdp(b, "Network.getCookies", params)
  result[:cookies]
end

function set_cookie!(b::Browser; name::String, value::String, domain::String,
                     path::String="/", httpOnly::Bool=false, secure::Bool=false,
                     sameSite::String="Lax", expires::Float64=-1.0)
  cookie = Dict{String,Any}(
    "name" => name, "value" => value, "domain" => domain,
    "path" => path, "httpOnly" => httpOnly, "secure" => secure,
    "sameSite" => sameSite
  )
  expires > 0 && (cookie["expires"] = expires)
  cdp(b, "Network.setCookie", cookie)
  "Cookie set: $name"
end

function clear_cookies!(b::Browser)
  cdp(b, "Network.clearBrowserCookies")
  "Cookies cleared"
end

# ── State-based interaction ──────────────────────────────────────

function index_page(b::Browser)
  js_code = read(joinpath(@__DIR__, "domstate.js"), String)
  js(b, js_code)
end

function interact!(b::Browser, index::Int, action::String, value::String="")
  js(b, """
    const el = window.__prosca_elements && window.__prosca_elements[$(index)];
    if (!el) throw new Error('Element index $(index) not found — call state(b) first');
    const action = $(JSON3.write(action));
    if (action === 'click') { el.click(); 'clicked' }
    else if (action === 'type') {
      el.focus();
      el.value = $(JSON3.write(value));
      el.dispatchEvent(new Event('input', {bubbles: true}));
      el.dispatchEvent(new Event('change', {bubbles: true}));
      'typed'
    }
    else if (action === 'select') {
      el.value = $(JSON3.write(value));
      el.dispatchEvent(new Event('change', {bubbles: true}));
      'selected'
    }
    else if (action === 'focus') { el.focus(); 'focused' }
    else { throw new Error('Unknown action: ' + action); }
  """)
end

export Browser, navigate!, click!, type!, submit!, text, html,
       js, cdp, screenshot, wait, cookies, set_cookie!, clear_cookies!,
       index_page, interact!
