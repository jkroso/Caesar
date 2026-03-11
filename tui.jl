# ═══════════════════════════════════════════════════════════════════════
# Prosca TUI — Tachikoma-based terminal interface for the Prosca agent
# ═══════════════════════════════════════════════════════════════════════

include("main.jl")

@use Tachikoma...
@use Tachikoma: view, update!, should_quit

# ── Model ─────────────────────────────────────────────────────────────

@kwdef mutable struct ProscaModel <: Model
  outbox::Channel       = Channel(32)
  inbox::Channel        = Channel(32)
  active_tab::Int       = 1               # 1=Chat, 2=Help, 3=Skills, 4=MCP
  input::TextInput      = TextInput(; label="You: ", focused=true, tick=0)
  messages::Vector{Vector{Span}} = Vector{Span}[]  # chat history as styled lines
  scroll::ScrollPane    = ScrollPane(Vector{Span}[]; following=true, word_wrap=true)
  pending_tool::Union{Nothing, ToolCallRequest} = nothing
  agent_busy::Bool      = false
  quit::Bool            = false
  # Autocomplete state
  completions::Vector{String} = String[]
  completion_idx::Int   = 0
end

should_quit(m::ProscaModel) = m.quit

# ── Tab labels ────────────────────────────────────────────────────────

const TAB_LABELS = Tachikoma.TabLabel["Chat", "Help", "Skills", "MCP"]

# ── Helpers ───────────────────────────────────────────────────────────

function push_chat!(m::ProscaModel, spans::Vector{Span})
  push!(m.messages, spans)
  push_line!(m.scroll, spans)
end

function push_chat!(m::ProscaModel, s::AbstractString, style::Style)
  push_chat!(m, [Span(s, style)])
end

function push_chat!(m::ProscaModel, prefix::AbstractString, prefix_style::Style,
                    body::AbstractString, body_style::Style)
  push_chat!(m, [Span(prefix, prefix_style), Span(body, body_style)])
end

function submit_input!(m::ProscaModel)
  input_text = String(strip(text(m.input)))
  isempty(input_text) && return
  if m.agent_busy
    push_chat!(m, "(Agent is thinking… please wait)", tstyle(:text_dim))
    return
  end
  clear!(m.input)

  # Handle ;commands inline
  if startswith(input_text, ";")
    parts = split(input_text, limit=2)
    cmd_name = String(parts[1][2:end])
    cmd_args = length(parts) > 1 ? String(strip(parts[2])) : ""
    push_chat!(m, "You: ", tstyle(:accent, bold=true), input_text, tstyle(:text))
    if haskey(COMMANDS, cmd_name)
      result = try
        COMMANDS[cmd_name].fn(cmd_args)
      catch e
        "Command error: $(sprint(showerror, e))"
      end
      push_chat!(m, string(result), tstyle(:text_dim))
    else
      push_chat!(m, "Unknown command: $cmd_name", tstyle(:error))
      push_chat!(m, "Available: $(join(keys(COMMANDS), ", "))", tstyle(:text_dim))
    end
    return
  end

  push_chat!(m, "You: ", tstyle(:accent, bold=true), input_text, tstyle(:text))
  m.agent_busy = true
  @async run_agent(input_text, m.outbox, m.inbox)
end

function handle_tool_approval!(m::ProscaModel, decision::Symbol)
  req = m.pending_tool
  req === nothing && return
  put!(m.inbox, ToolApproval(req.id, decision))
  label = decision == :allow ? "Allowed" : decision == :always ? "Always" : "Denied"
  push_chat!(m, "  [$label]", tstyle(decision == :deny ? :error : :success, bold=true))
  m.pending_tool = nothing
end

# ── Autocomplete ─────────────────────────────────────────────────────

function gather_completions(prefix::String)::Vector{String}
  results = String[]
  if startswith(prefix, ";model ")
    # Model name completion
    partial = strip(prefix[8:end])
    model_mod = get(COMMANDS, "model", nothing)
    if model_mod !== nothing && isdefined(model_mod, :PROVIDERS)
      for (_, _, _, _, models) in model_mod.PROVIDERS
        for m in models
          startswith(m, partial) && push!(results, ";model " * m)
        end
      end
    end
  elseif startswith(prefix, ";") || startswith(prefix, "/")
    # Show both commands and skills for either prefix
    partial = prefix[2:end]
    for name in keys(COMMANDS)
      startswith(name, partial) && push!(results, ";" * name)
    end
    for name in keys(SKILLS)
      startswith(name, partial) && push!(results, "/" * name)
    end
  else
    # MCP tool completion (server.tool format)
    for (sname, server) in MCP_SERVERS
      server.connected || continue
      for t in server.tools
        full = "$sname.$(t.name)"
        startswith(full, prefix) && push!(results, full)
      end
    end
  end
  sort!(results)
end

function dismiss_completions!(m::ProscaModel)
  empty!(m.completions)
  m.completion_idx = 0
end

function refresh_completions!(m::ProscaModel)
  current = String(strip(text(m.input)))
  m.completions = gather_completions(current)
  m.completion_idx = isempty(m.completions) ? 0 : 1
end

function accept_completion!(m::ProscaModel)
  if !isempty(m.completions) && m.completion_idx > 0
    set_text!(m.input, m.completions[m.completion_idx] * " ")
    dismiss_completions!(m)
  end
end

function handle_tab!(m::ProscaModel)
  if isempty(m.completions)
    refresh_completions!(m)
  else
    # Cycle forward
    m.completion_idx = mod1(m.completion_idx + 1, length(m.completions))
  end
end

function handle_backtab!(m::ProscaModel)
  isempty(m.completions) && return
  m.completion_idx = mod1(m.completion_idx - 1, length(m.completions))
end

# ── Poll agent channel events ─────────────────────────────────────────

function drain_agent_events!(m::ProscaModel)
  while isready(m.outbox)
    event = take!(m.outbox)
    if event isa AgentMessage
      push_chat!(m, "Agent: ", tstyle(:primary, bold=true), event.text, tstyle(:text))
    elseif event isa ToolCallRequest
      push_chat!(m, "  Tool: $(event.name) ", tstyle(:accent, bold=true),
                 event.args, tstyle(:text_dim))
      m.pending_tool = event
      push_chat!(m, "  [y]Allow [n]Deny [a]Always", tstyle(:accent))
    elseif event isa ToolResult
      # Tool results are shown in the agent's final answer; skip display here
    elseif event isa AgentDone
      m.agent_busy = false
    end
  end
end

# ── Event handling ────────────────────────────────────────────────────

function update!(m::ProscaModel, e::KeyEvent)
  # Quit: Ctrl+Q (byte 0x11 -> char 'q')
  if e.key == :ctrl && e.char == 'q'
    m.quit = true
    return
  end
  # Also handle Ctrl+C as quit
  if e.key == :ctrl_c
    m.quit = true
    return
  end

  # Tab switching: Ctrl+N (next) / Ctrl+P (prev)
  if e.key == :ctrl && e.char == 'n'
    m.active_tab = mod1(m.active_tab + 1, 4)
    return
  end
  if e.key == :ctrl && e.char == 'p'
    m.active_tab = mod1(m.active_tab - 1, 4)
    return
  end

  # Tool approval when pending
  if m.pending_tool !== nothing
    if e.key == :char && e.char == 'y'
      handle_tool_approval!(m, :allow)
      return
    elseif e.key == :char && e.char == 'n'
      handle_tool_approval!(m, :deny)
      return
    elseif e.key == :char && e.char == 'a'
      handle_tool_approval!(m, :always)
      return
    end
  end

  # Chat tab: input handling
  if m.active_tab == 1
    # Tab/Shift+Tab: cycle completions (or trigger if none)
    if e.key == :tab
      if !isempty(m.completions)
        handle_tab!(m)
      else
        handle_tab!(m)
      end
      return
    end
    if e.key == :backtab
      handle_backtab!(m)
      return
    end
    # Arrow keys: navigate completions when popup is open
    if !isempty(m.completions)
      if e.key == :down
        m.completion_idx = mod1(m.completion_idx + 1, length(m.completions))
        return
      end
      if e.key == :up
        m.completion_idx = mod1(m.completion_idx - 1, length(m.completions))
        return
      end
    end
    # Escape: dismiss completions
    if e.key == :escape && !isempty(m.completions)
      dismiss_completions!(m)
      return
    end
    # Enter: accept completion if popup is open, otherwise submit
    if e.key == :enter
      if !isempty(m.completions) && m.completion_idx > 0
        accept_completion!(m)
        return
      end
      submit_input!(m)
      return
    end
    # Scroll: PageUp/PageDown
    if e.key == :pageup || e.key == :pagedown
      handle_key!(m.scroll, e)
      return
    end
    # Forward to text input, then refresh completions based on new text
    handle_key!(m.input, e)
    current = String(strip(text(m.input)))
    if !isempty(current) && (startswith(current, ";") || startswith(current, "/"))
      refresh_completions!(m)
    else
      !isempty(m.completions) && dismiss_completions!(m)
    end
    return
  end

  # Other tabs: scroll with arrows
  if m.active_tab in (2, 3, 4)
    # No specific handling needed for static tabs
    return
  end
end

# ── View rendering ────────────────────────────────────────────────────

function view(m::ProscaModel, f::Frame)
  # Drain agent events each frame
  drain_agent_events!(m)

  buf = f.buffer
  area = f.area

  # Layout: tab bar (1) | content (fill) | input (3 for label+input+border) | status (1)
  layout = Layout(Vertical, Constraint[Fixed(1), Fill(), Fixed(3), Fixed(1)])
  rects = split_layout(layout, area)

  tab_rect, content_rect, input_rect, status_rect = rects[1], rects[2], rects[3], rects[4]

  # ── Tab bar ──
  tabs = TabBar(TAB_LABELS; active=m.active_tab)
  render(tabs, tab_rect, buf)

  # ── Content area ──
  if m.active_tab == 1
    render_chat!(m, content_rect, buf)
  elseif m.active_tab == 2
    render_help!(content_rect, buf)
  elseif m.active_tab == 3
    render_skills!(content_rect, buf)
  elseif m.active_tab == 4
    render_mcp!(content_rect, buf)
  end

  # ── Completion popup (rendered over bottom of content area) ──
  if !isempty(m.completions) && m.active_tab == 1
    n = length(m.completions)
    max_show = min(n, 8)
    max_w = maximum(textwidth, m.completions) + 4
    popup_w = min(max_w, content_rect.width - 2)
    popup_h = max_show + 2  # +2 for border
    popup_x = content_rect.x + 1
    popup_y = max(content_rect.y, bottom(content_rect) - popup_h + 1)
    popup_rect = Rect(popup_x, popup_y, popup_w, popup_h)
    popup_block = Block(title="Tab:next Esc:close", border_style=tstyle(:accent),
                        title_style=tstyle(:text_dim))
    popup_inner = render(popup_block, popup_rect, buf)
    # Scroll window around selected item
    offset = max(0, m.completion_idx - max_show)
    for i in 1:max_show
      idx = offset + i
      idx > n && break
      y = popup_inner.y + (i - 1)
      y > bottom(popup_inner) && break
      is_sel = idx == m.completion_idx
      s = is_sel ? Style(; fg=Color256(0), bg=tstyle(:accent).fg, bold=true) : tstyle(:text_dim)
      # Clear the line first
      for x in popup_inner.x:right(popup_inner)
        set_char!(buf, x, y, ' ', s)
      end
      label = " " * m.completions[idx]
      set_string!(buf, popup_inner.x, y, label, s; max_x=right(popup_inner))
    end
  end

  # ── Input area ──
  input_block = Block(title="Input", border_style=tstyle(:border),
                      title_style=tstyle(:accent, bold=true))
  inner = render(input_block, input_rect, buf)
  render(m.input, inner, buf)

  # ── Status bar ──
  status_left = Span[]
  if m.agent_busy
    push!(status_left, Span(" Working... ", tstyle(:accent, bold=true)))
  elseif m.pending_tool !== nothing
    push!(status_left, Span(" Awaiting approval ", tstyle(:error, bold=true)))
  else
    push!(status_left, Span(" Ready ", tstyle(:success)))
  end

  status_right = Span[
    Span("^N/^P:tabs ", tstyle(:text_dim)),
    Span("Ctrl+Q:quit ", tstyle(:text_dim)),
    Span("$(CONFIG["llm"]) ", tstyle(:primary)),
  ]
  sbar = StatusBar(; left=status_left, right=status_right,
                   style=Style(; bg=tstyle(:border).fg))
  render(sbar, status_rect, buf)
end

# ── Tab renderers ─────────────────────────────────────────────────────

function render_chat!(m::ProscaModel, rect::Rect, buf::Buffer)
  # Use the shared ScrollPane which tracks messages
  m.scroll.block = Block(title="Chat", border_style=tstyle(:border),
                         title_style=tstyle(:primary, bold=true))
  render(m.scroll, rect, buf)
end

function render_help!(rect::Rect, buf::Buffer)
  help_lines = [
    "Prosca TUI - Keyboard Shortcuts",
    "",
    "  Ctrl+N      Next tab",
    "  Ctrl+P      Previous tab",
    "  Ctrl+Q      Quit",
    "  Tab         Autocomplete (;commands, /skills, tools)",
    "  Enter       Send message",
    "  PageUp/Dn   Scroll chat",
    "",
    "Tool Approval (when prompted):",
    "  y           Allow once",
    "  n           Deny",
    "  a           Allow always (this session)",
    "",
    "Commands (prefix with ;):",
  ]

  # Add loaded commands
  for (name, mod) in COMMANDS
    desc = hasproperty(mod, :description) ? mod.description : ""
    push!(help_lines, "  ;$name  $desc")
  end

  p = Paragraph(join(help_lines, "\n");
                block=Block(title="Help", border_style=tstyle(:border),
                            title_style=tstyle(:primary, bold=true)),
                wrap=word_wrap)
  render(p, rect, buf)
end

function render_skills!(rect::Rect, buf::Buffer)
  if isempty(SKILLS)
    lines = ["No skills loaded.", "", "Add .md files to: $(SKILLS_DIR)"]
  else
    lines = String["Loaded Skills:", ""]
    for (name, skill) in SKILLS
      push!(lines, "  /$name")
      if !isempty(skill.description)
        push!(lines, "    $(skill.description)")
      end
      push!(lines, "")
    end
  end
  p = Paragraph(join(lines, "\n");
                block=Block(title="Skills", border_style=tstyle(:border),
                            title_style=tstyle(:primary, bold=true)),
                wrap=word_wrap)
  render(p, rect, buf)
end

function render_mcp!(rect::Rect, buf::Buffer)
  lines = String["MCP Servers", ""]
  if isempty(MCP_SERVERS)
    push!(lines, "  No MCP servers configured.")
    push!(lines, "")
    push!(lines, "  Add servers to: ~/Prosca/mcp_servers.json")
  else
    for (name, server) in MCP_SERVERS
      status = server.connected ? "connected" : "disconnected"
      runtime_tag = server.is_runtime ? " [runtime]" : ""
      push!(lines, "  $(name)$(runtime_tag) — $(status)")
      push!(lines, "    $(server.url)")
      push!(lines, "    $(length(server.tools)) tools")
      for t in server.tools
        push!(lines, "      $(t.name): $(t.description)")
      end
      push!(lines, "")
    end
  end
  p = Paragraph(join(lines, "\n");
                block=Block(title="MCP", border_style=tstyle(:border),
                            title_style=tstyle(:primary, bold=true)),
                wrap=word_wrap)
  render(p, rect, buf)
end

# ── Launch ────────────────────────────────────────────────────────────

let model = ProscaModel()
  # Show welcome message
  push_chat!(model, "Prosca started", tstyle(:success, bold=true))
  push_chat!(model, "Brain: $HOME", tstyle(:text_dim))
  push_chat!(model, "Model: $(CONFIG["llm"])", tstyle(:text_dim))
  # Show MCP server status
  rt = runtime_server()
  if rt !== nothing
    push_chat!(model, "Runtime: $(rt.name) ($(length(rt.tools)) tools)", tstyle(:text_dim))
  else
    push_chat!(model, "Runtime: not connected (configure mcp_servers.json)", tstyle(:error))
  end
  push_chat!(model, "Type a message and press Enter. ^N/^P to switch tabs.", tstyle(:text_dim))
  push_chat!(model, "", tstyle(:text))
  app(model; default_bindings=true)
end
