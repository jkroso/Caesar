# captcha.jl — Captcha solver via capsolver.com
#
# Auto-detects reCAPTCHA v2/v3, hCaptcha, and Cloudflare Turnstile.
# Sends to capsolver API, polls for solution, injects token into the page.

@use HTTP
@use JSON3
@use YAML
@use "./browser" Browser js

const CAPSOLVER_API = "https://api.capsolver.com"
const API_KEY_CACHE = Ref{String}("")

function capsolver_key()
  isempty(API_KEY_CACHE[]) || return API_KEY_CACHE[]
  cfg = YAML.load_file(joinpath(homedir(), "Caesar", "config.yaml"))
  key = get(cfg, "capsolver_key", nothing)
  key === nothing && error("Set capsolver_key in ~/Caesar/config.yaml")
  API_KEY_CACHE[] = string(key)
end

# ── Detection ────────────────────────────────────────────────────────

function detect_captcha(b::Browser)
  js(b, """
    (() => {
      // reCAPTCHA v2
      const recapEl = document.querySelector('.g-recaptcha[data-sitekey]');
      if (recapEl && !recapEl.classList.contains('cf-turnstile')) {
        return {
          type: 'recaptchav2',
          sitekey: recapEl.getAttribute('data-sitekey'),
          invisible: recapEl.getAttribute('data-size') === 'invisible'
        };
      }

      // reCAPTCHA v3 (render param in script src)
      for (const s of document.querySelectorAll('script[src]')) {
        const m = s.src.match(/recaptcha.*[?&]render=([^&]+)/);
        if (m && m[1] !== 'explicit') return {type: 'recaptchav3', sitekey: m[1]};
      }

      // reCAPTCHA via iframe fallback
      const recapFrame = document.querySelector('iframe[src*="google.com/recaptcha"], iframe[src*="recaptcha.net"]');
      if (recapFrame) {
        const m = recapFrame.src.match(/[?&]k=([^&]+)/);
        if (m) return {type: 'recaptchav2', sitekey: m[1], invisible: false};
      }

      // hCaptcha
      const hEl = document.querySelector('.h-captcha[data-sitekey]');
      if (hEl) {
        return {
          type: 'hcaptcha',
          sitekey: hEl.getAttribute('data-sitekey'),
          invisible: hEl.getAttribute('data-size') === 'invisible'
        };
      }
      const hFrame = document.querySelector('iframe[src*="hcaptcha.com"]');
      if (hFrame) {
        const m = hFrame.src.match(/sitekey=([^&]+)/);
        if (m) return {type: 'hcaptcha', sitekey: m[1]};
      }

      // Cloudflare Turnstile
      const tEl = document.querySelector('.cf-turnstile[data-sitekey]');
      if (tEl) {
        return {
          type: 'turnstile',
          sitekey: tEl.getAttribute('data-sitekey'),
          action: tEl.getAttribute('data-action') || null,
          cdata: tEl.getAttribute('data-cdata') || null
        };
      }

      return null;
    })()
  """)
end

# ── Capsolver API ────────────────────────────────────────────────────

function create_task(task::Dict)
  body = JSON3.write(Dict("clientKey" => capsolver_key(), "task" => task))
  resp = HTTP.post("$CAPSOLVER_API/createTask",
    ["Content-Type" => "application/json"], body;
    connect_timeout=10, readtimeout=30)
  data = JSON3.read(String(resp.body))
  get(data, :errorId, 1) != 0 && error("Capsolver: $(get(data, :errorCode, "?")) — $(get(data, :errorDescription, ""))")
  string(data.taskId)
end

function poll_result(task_id::String; max_polls::Int=40, interval::Int=3)
  for i in 1:max_polls
    body = JSON3.write(Dict("clientKey" => capsolver_key(), "taskId" => task_id))
    resp = HTTP.post("$CAPSOLVER_API/getTaskResult",
      ["Content-Type" => "application/json"], body;
      connect_timeout=10, readtimeout=30)
    data = JSON3.read(String(resp.body))
    get(data, :errorId, 1) != 0 && error("Capsolver: $(get(data, :errorCode, "?")) — $(get(data, :errorDescription, ""))")
    string(data.status) == "ready" && return data.solution
    sleep(interval)
  end
  error("Capsolver: timed out after $(max_polls * interval)s")
end

# ── Solve by type ────────────────────────────────────────────────────

function request_solve(type::String, url::String, sitekey::String; kwargs...)
  task = Dict{String,Any}("type" => type, "websiteURL" => url, "websiteKey" => sitekey)
  for (k, v) in kwargs
    v === nothing && continue
    task[string(k)] = v
  end
  task_id = create_task(task)
  poll_result(task_id)
end

# ── Inject solution ──────────────────────────────────────────────────

function inject_recaptcha!(b::Browser, token::String)
  t = JSON3.write(token)
  js(b, """
    (() => {
      document.querySelectorAll('#g-recaptcha-response, textarea[name="g-recaptcha-response"]')
        .forEach(el => { el.style.display = 'block'; el.value = $t; });
      // Fire the callback if registered
      try {
        if (typeof ___grecaptcha_cfg !== 'undefined' && ___grecaptcha_cfg.clients) {
          const findCb = (obj, d=0) => {
            if (d > 5 || !obj || typeof obj !== 'object') return null;
            for (const k of Object.keys(obj)) {
              if (k === 'callback' && typeof obj[k] === 'function') return obj[k];
              const r = findCb(obj[k], d+1);
              if (r) return r;
            }
            return null;
          };
          for (const c of Object.values(___grecaptcha_cfg.clients)) {
            const cb = findCb(c);
            if (cb) { cb($t); break; }
          }
        }
      } catch(e) {}
      return 'injected';
    })()
  """)
end

function inject_hcaptcha!(b::Browser, token::String)
  t = JSON3.write(token)
  js(b, """
    (() => {
      document.querySelectorAll('textarea[name="h-captcha-response"], [name="h-captcha-response"]')
        .forEach(el => el.value = $t);
      try {
        if (typeof hcaptcha !== 'undefined') {
          const iframe = document.querySelector('iframe[src*="hcaptcha.com"]');
          if (iframe) iframe.contentWindow.postMessage({source:'hcaptcha',type:'set-response',response:$t}, '*');
        }
      } catch(e) {}
      return 'injected';
    })()
  """)
end

function inject_turnstile!(b::Browser, token::String)
  t = JSON3.write(token)
  js(b, """
    (() => {
      document.querySelectorAll('input[name="cf-turnstile-response"], [name="cf-turnstile-response"]')
        .forEach(el => el.value = $t);
      try {
        const w = document.querySelector('.cf-turnstile');
        if (w && typeof turnstile !== 'undefined') {
          const id = turnstile.getWidgetId && turnstile.getWidgetId(w);
          if (id) turnstile.execute(id);
        }
      } catch(e) {}
      return 'injected';
    })()
  """)
end

# ── Main entry point ─────────────────────────────────────────────────

function solve_captcha!(b::Browser)
  info = detect_captcha(b)
  info === nothing && error("No captcha detected on page")

  url = js(b, "window.location.href")
  ctype = string(info.type)
  sitekey = string(info.sitekey)

  if ctype == "recaptchav2"
    invisible = get(info, :invisible, false) === true
    sol = request_solve("ReCaptchaV2TaskProxyLess", url, sitekey; isInvisible=invisible)
    token = string(sol.gRecaptchaResponse)
    inject_recaptcha!(b, token)
  elseif ctype == "recaptchav3"
    sol = request_solve("ReCaptchaV3TaskProxyLess", url, sitekey; pageAction="verify")
    token = string(sol.gRecaptchaResponse)
    inject_recaptcha!(b, token)
  elseif ctype == "hcaptcha"
    invisible = get(info, :invisible, false) === true
    sol = request_solve("HCaptchaTaskProxyLess", url, sitekey; isInvisible=invisible)
    token = string(sol.gRecaptchaResponse)
    inject_hcaptcha!(b, token)
  elseif ctype == "turnstile"
    action = let v = get(info, :action, nothing); v === nothing || v === false ? nothing : string(v) end
    cdata  = let v = get(info, :cdata, nothing);  v === nothing || v === false ? nothing : string(v) end
    metadata = Dict{String,Any}()
    action !== nothing && (metadata["action"] = action)
    cdata  !== nothing && (metadata["cdata"] = cdata)
    kw = isempty(metadata) ? (;) : (; metadata)
    sol = request_solve("AntiTurnstileTaskProxyLess", url, sitekey; kw...)
    token = string(sol.token)
    inject_turnstile!(b, token)
  else
    error("Unknown captcha type: $ctype")
  end

  "Solved $ctype (sitekey: $(sitekey[1:min(12,end)])…)"
end

export detect_captcha, solve_captcha!
