# browser.jl — Chrome DevTools Protocol client for browser automation
#
# Launches headless Chrome and controls it via CDP over WebSocket.
# Cookie state persists across sessions via a dedicated user-data-dir.

@use HTTP
@use JSON3

# ── Types ────────────────────────────────────────────────────────────

mutable struct CDPSession
  process::Base.Process
  send_ch::Channel{Tuple{String, Channel}}
  msg_id::Int
  running::Bool
  ready::Channel{Nothing}
end

const _SESSION = Ref{Union{CDPSession, Nothing}}(nothing)
const CHROME_PATH = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const DATA_DIR = joinpath(homedir(), "Prosca", "browser-data")

# ── Connection ───────────────────────────────────────────────────────

function browser_open(; port::Int=9222)
  _SESSION[] !== nothing && return "Browser already open"
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
      # If no page target exists, create one
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
  session = CDPSession(proc, send_ch, 0, true, ready_ch)

  # WebSocket connection runs in background task
  @async begin
    try
      HTTP.WebSockets.open(ws_url) do ws
        responses = Dict{Int, Channel}()

        # Reader task
        @async begin
          try
            while session.running
              data = HTTP.WebSockets.receive(ws)
              msg = JSON3.read(String(data))
              if msg isa AbstractDict && haskey(msg, :id)
                ch = get(responses, msg[:id], nothing)
                ch !== nothing && put!(ch, msg)
              end
            end
          catch
            session.running = false
          end
        end

        put!(ready_ch, nothing)  # signal that WebSocket is connected

        # Writer loop — processes send requests, keeps connection alive
        for (json_msg, resp_ch) in send_ch
          session.running || break
          parsed = JSON3.read(json_msg)
          responses[parsed[:id]] = resp_ch
          HTTP.WebSockets.send(ws, json_msg)
        end
      end
    catch e
      session.running = false
      isopen(ready_ch) && put!(ready_ch, nothing)
    end
  end

  _SESSION[] = session
  take!(ready_ch)  # wait for WebSocket to connect

  # Enable required CDP domains
  _cdp("Page.enable")
  _cdp("Runtime.enable")
  _cdp("Network.enable")
  "Browser opened"
end

function browser_close()
  s = _SESSION[]
  s === nothing && return "No browser open"
  s.running = false
  close(s.send_ch)
  # Kill Chrome and all its child processes
  try
    pid = getpid(s.process)
    run(`pkill -P $pid`; wait=false)
    kill(s.process)
  catch end
  _SESSION[] = nothing
  "Browser closed"
end

# ── CDP transport ────────────────────────────────────────────────────

function _cdp(method::String, params::Dict{String,Any}=Dict{String,Any}(); timeout::Int=30)
  s = _SESSION[]
  s === nothing && error("Browser not open. Call browser_open() first.")
  s.running || error("Browser session is closed")

  s.msg_id += 1
  id = s.msg_id
  resp_ch = Channel{Any}(1)
  msg = JSON3.write(Dict("id" => id, "method" => method, "params" => params))
  put!(s.send_ch, (msg, resp_ch))

  result = timedwait(() -> isready(resp_ch), float(timeout))
  result == :timed_out && error("CDP command timed out: $method")

  resp = take!(resp_ch)
  if resp isa AbstractDict && haskey(resp, :error)
    error("CDP error: $(JSON3.write(resp[:error]))")
  end
  get(resp, :result, nothing)
end

# ── Navigation ───────────────────────────────────────────────────────

function browser_navigate(url::String)
  _cdp("Page.navigate", Dict{String,Any}("url" => url))
  # Wait for page load
  sleep(1)
  _cdp("Runtime.evaluate", Dict{String,Any}(
    "expression" => "document.readyState",
    "returnByValue" => true
  ))
  "Navigated to $url"
end

# ── DOM interaction ──────────────────────────────────────────────────

function browser_click(selector::String)
  _js("""
    const el = document.querySelector($(JSON3.write(selector)));
    if (!el) throw new Error('Element not found: $(escape_string(selector))');
    el.click();
    'clicked'
  """)
end

function browser_type(selector::String, text::String)
  # Focus the element and set value, dispatching input events
  _js("""
    const el = document.querySelector($(JSON3.write(selector)));
    if (!el) throw new Error('Element not found: $(escape_string(selector))');
    el.focus();
    el.value = $(JSON3.write(text));
    el.dispatchEvent(new Event('input', {bubbles: true}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
    'typed'
  """)
end

function browser_submit(selector::String)
  _js("""
    const el = document.querySelector($(JSON3.write(selector)));
    if (!el) throw new Error('Element not found: $(escape_string(selector))');
    const form = el.closest('form') || el;
    if (form.submit) { form.submit(); 'submitted' }
    else { el.click(); 'clicked' }
  """)
end

# ── Reading ──────────────────────────────────────────────────────────

function browser_text(selector::String="body")
  _js("""
    const el = document.querySelector($(JSON3.write(selector)));
    el ? el.innerText : ''
  """)
end

function browser_html(selector::String="body")
  _js("""
    const el = document.querySelector($(JSON3.write(selector)));
    el ? el.innerHTML : ''
  """)
end

function browser_url()
  _js("window.location.href")
end

function browser_title()
  _js("document.title")
end

# ── JavaScript ───────────────────────────────────────────────────────

function browser_eval(js::String)
  _js(js)
end

function _js(expression::String)
  result = _cdp("Runtime.evaluate", Dict{String,Any}(
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

function browser_screenshot(; path::Union{String,Nothing}=nothing)
  result = _cdp("Page.captureScreenshot", Dict{String,Any}("format" => "png"))
  data = Base64.base64decode(result[:data])
  out = path !== nothing ? path : tempname() * ".png"
  write(out, data)
  out
end

# ── Wait ─────────────────────────────────────────────────────────────

function browser_wait(selector::String; timeout::Int=10)
  deadline = time() + timeout
  while time() < deadline
    found = _js("""document.querySelector($(JSON3.write(selector))) !== null""")
    found === true && return true
    sleep(0.3)
  end
  error("Timeout waiting for element: $selector")
end

# ── Cookies ──────────────────────────────────────────────────────────

function browser_cookies(; url::Union{String,Nothing}=nothing)
  params = Dict{String,Any}()
  url !== nothing && (params["urls"] = [url])
  result = _cdp("Network.getCookies", params)
  result[:cookies]
end

function browser_set_cookie(; name::String, value::String, domain::String,
                             path::String="/", httpOnly::Bool=false, secure::Bool=false,
                             sameSite::String="Lax", expires::Float64=-1.0)
  cookie = Dict{String,Any}(
    "name" => name, "value" => value, "domain" => domain,
    "path" => path, "httpOnly" => httpOnly, "secure" => secure,
    "sameSite" => sameSite
  )
  expires > 0 && (cookie["expires"] = expires)
  _cdp("Network.setCookie", cookie)
  "Cookie set: $name"
end

function browser_clear_cookies()
  _cdp("Network.clearBrowserCookies")
  "Cookies cleared"
end

@use Base64
