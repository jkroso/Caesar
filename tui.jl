# ═══════════════════════════════════════════════════════════════════════
# Prosca TUI — Tachikoma-based terminal interface for the Prosca agent
# ═══════════════════════════════════════════════════════════════════════

@use "."... AGENTS
@use Tachikoma...
@use CommonMark

# ── Model ─────────────────────────────────────────────────────────────

@kwdef mutable struct ProscaModel <: Model
  outbox::Channel       = Channel(32)
  inbox::Channel        = Channel(32)
  active_tab::Int       = 1               # 1=Chat, 2=Help, 3=Skills, 4=Agents
  input::TextInput      = TextInput(; label="You: ", focused=true, tick=0)
  messages::Vector{Vector{Span}} = Vector{Span}[]
  scroll::ScrollPane    = ScrollPane(Vector{Span}[]; following=true, word_wrap=true)
  repl_scroll::ScrollPane = ScrollPane(Vector{Span}[]; following=true, word_wrap=true)
  repl_log_pos::Int     = 0               # bytes read so far from repl.log
  pending_tool::Union{Nothing, ToolCallRequest} = nothing
  agent_busy::Bool      = false
  quit::Bool            = false
  completions::Vector{String} = String[]
  completion_idx::Int   = 0
end

Tachikoma.should_quit(m::ProscaModel) = m.quit

# ── Tab labels ────────────────────────────────────────────────────────

const TAB_LABELS = Tachikoma.TabLabel["Chat", "Help", "Skills", "Agents"]

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

function push_markdown!(m::ProscaModel, prefix::AbstractString, prefix_style::Style,
                        md_text::AbstractString)
  width = max(20, 80)  # reasonable default; scroll pane handles wrapping too
  lines = markdown_to_spans(md_text, width)
  for (i, line) in enumerate(lines)
    if i == 1
      pushfirst!(line, Span(prefix, prefix_style))
    end
    push!(m.messages, line)
    push_line!(m.scroll, line)
  end
end

function submit_input!(m::ProscaModel)
  input_text = String(strip(text(m.input)))
  isempty(input_text) && return
  if m.agent_busy
    push_chat!(m, "(Agent is thinking… please wait)", tstyle(:text_dim))
    return
  end
  clear!(m.input)

  # Handle /commands inline
  if startswith(input_text, "/") && !startswith(input_text, "//")
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
  agent = default_agent()
  @async run_agent(input_text, agent; outbox=m.outbox, inbox=m.inbox)
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
  if startswith(prefix, "/model ")
    partial = strip(prefix[8:end])
    model_mod = get(COMMANDS, "model", nothing)
    if model_mod !== nothing && isdefined(model_mod, :PROVIDERS)
      for (_, _, _, _, models) in model_mod.PROVIDERS
        for m in models
          startswith(m, partial) && push!(results, "/model " * m)
        end
      end
    end
  elseif startswith(prefix, "/")
    partial = prefix[2:end]
    for name in keys(COMMANDS)
      startswith(name, partial) && push!(results, "/" * name)
    end
    for name in keys(SKILLS)
      startswith(name, partial) && push!(results, "/" * name)
    end
  end
  sort!(results)
end

function dismiss_completions!(m::ProscaModel)
  empty!(m.completions)
  m.completion_idx = 0
end

function refresh_completions!(m::ProscaModel)
  current = String(text(m.input))
  m.completions = gather_completions(current)
  m.completion_idx = isempty(m.completions) ? 0 : 1
end

function accept_completion!(m::ProscaModel)
  if !isempty(m.completions) && m.completion_idx > 0
    set_text!(m.input, m.completions[m.completion_idx] * " ")
    refresh_completions!(m)
  end
end

function handle_tab!(m::ProscaModel)
  if isempty(m.completions)
    refresh_completions!(m)
  else
    m.completion_idx = mod1(m.completion_idx + 1, length(m.completions))
  end
end

function handle_backtab!(m::ProscaModel)
  isempty(m.completions) && return
  m.completion_idx = mod1(m.completion_idx - 1, length(m.completions))
end

# ── Poll REPL log for new lines ───────────────────────────────────────

function poll_repl_log!(m::ProscaModel)
  isempty(AGENTS) && return
  agent = default_agent()
  logpath = string(agent.path * "repl.log")
  isfile(logpath) || return
  sz = filesize(logpath)
  sz <= m.repl_log_pos && return
  new_text = open(logpath) do io
    seek(io, m.repl_log_pos)
    txt = read(io, String)
    m.repl_log_pos = position(io)
    txt
  end
  for line in split(new_text, '\n')
    style = if startswith(line, "julia>")
      tstyle(:accent, bold=true)
    elseif startswith(line, "       ")
      tstyle(:accent)
    elseif startswith(line, "ERROR:")
      tstyle(:error)
    else
      tstyle(:text_dim)
    end
    push_line!(m.repl_scroll, [Span(line, style)])
  end
end

# ── Poll agent channel events ─────────────────────────────────────────

function drain_agent_events!(m::ProscaModel)
  while isready(m.outbox)
    event = take!(m.outbox)
    if event isa AgentMessage
      if markdown_extension_loaded()
        push_markdown!(m, "Agent: ", tstyle(:primary, bold=true), event.text)
      else
        push_chat!(m, "Agent: ", tstyle(:primary, bold=true), event.text, tstyle(:text))
      end
    elseif event isa ToolCallRequest
      push_chat!(m, "  Tool: $(event.name) ", tstyle(:accent, bold=true),
                 event.args, tstyle(:text_dim))
      m.pending_tool = event
      push_chat!(m, "  [y]Allow [n]Deny [a]Always", tstyle(:accent))
    elseif event isa ToolResult
      # Tool results are shown in the agent's final answer
    elseif event isa AgentDone
      m.agent_busy = false
    end
  end
end

# ── Event handling ────────────────────────────────────────────────────

function Tachikoma.update!(m::ProscaModel, e::KeyEvent)
  if e.key == :ctrl && e.char == 'q'
    m.quit = true
    return
  end
  if e.key == :ctrl_c
    m.quit = true
    return
  end

  if e.key == :ctrl && e.char == 'n'
    m.active_tab = mod1(m.active_tab + 1, 4)
    return
  end
  if e.key == :ctrl && e.char == 'p'
    m.active_tab = mod1(m.active_tab - 1, 4)
    return
  end

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

  if m.active_tab == 1
    if e.key == :tab
      handle_tab!(m)
      return
    end
    if e.key == :backtab
      handle_backtab!(m)
      return
    end
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
    if e.key == :escape && !isempty(m.completions)
      dismiss_completions!(m)
      return
    end
    if e.key == :enter
      if !isempty(m.completions) && m.completion_idx > 0
        selected = m.completions[m.completion_idx]
        current_text = strip(String(text(m.input)))
        if current_text == selected || current_text == selected * " "
          # Input already matches the selection — submit it
          dismiss_completions!(m)
          submit_input!(m)
        else
          accept_completion!(m)
        end
        return
      end
      submit_input!(m)
      return
    end
    if e.key == :pageup || e.key == :pagedown
      handle_key!(m.scroll, e)
      return
    end
    handle_key!(m.input, e)
    current = String(text(m.input))
    trimmed = strip(current)
    if !isempty(trimmed) && startswith(trimmed, "/")
      refresh_completions!(m)
    else
      !isempty(m.completions) && dismiss_completions!(m)
    end
    return
  end

  if m.active_tab in (2, 3, 4)
    return
  end
end

# ── View rendering ────────────────────────────────────────────────────

function Tachikoma.view(m::ProscaModel, f::Frame)
  drain_agent_events!(m)
  poll_repl_log!(m)

  buf = f.buffer
  area = f.area

  layout = Layout(Vertical, Constraint[Fixed(1), Fill(), Fixed(3), Fixed(1)])
  rects = split_layout(layout, area)

  tab_rect, content_rect, input_rect, status_rect = rects[1], rects[2], rects[3], rects[4]

  tabs = TabBar(TAB_LABELS; active=m.active_tab)
  render(tabs, tab_rect, buf)

  if m.active_tab == 1
    # Split content: chat on left, REPL log on right
    hsplit = Layout(Horizontal, Constraint[Tachikoma.Percent(60), Tachikoma.Percent(40)])
    hpanes = split_layout(hsplit, content_rect)
    render_chat!(m, hpanes[1], buf)
    render_repl_log!(m, hpanes[2], buf)
  elseif m.active_tab == 2
    render_help!(content_rect, buf)
  elseif m.active_tab == 3
    render_skills!(content_rect, buf)
  elseif m.active_tab == 4
    render_agents!(content_rect, buf)
  end

  # Completion popup
  if !isempty(m.completions) && m.active_tab == 1
    n = length(m.completions)
    max_show = min(n, 8)
    max_w = maximum(textwidth, m.completions) + 4
    popup_w = min(max_w, content_rect.width - 2)
    popup_h = max_show + 2
    popup_x = content_rect.x + 1
    popup_y = max(content_rect.y, bottom(content_rect) - popup_h + 1)
    popup_rect = Rect(popup_x, popup_y, popup_w, popup_h)
    popup_block = Block(title="Tab:next Esc:close", border_style=tstyle(:accent),
                        title_style=tstyle(:text_dim))
    popup_inner = render(popup_block, popup_rect, buf)
    offset = max(0, m.completion_idx - max_show)
    for i in 1:max_show
      idx = offset + i
      idx > n && break
      y = popup_inner.y + (i - 1)
      y > bottom(popup_inner) && break
      is_sel = idx == m.completion_idx
      s = is_sel ? Style(; fg=Color256(0), bg=tstyle(:accent).fg, bold=true) : tstyle(:text_dim)
      for x in popup_inner.x:right(popup_inner)
        set_char!(buf, x, y, ' ', s)
      end
      label = " " * m.completions[idx]
      set_string!(buf, popup_inner.x, y, label, s; max_x=right(popup_inner))
    end
  end

  input_block = Block(title="Input", border_style=tstyle(:border),
                      title_style=tstyle(:accent, bold=true))
  inner = render(input_block, input_rect, buf)
  render(m.input, inner, buf)

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
    Span("$(get(CONFIG, "llm", "")) ", tstyle(:primary)),
  ]
  sbar = StatusBar(; left=status_left, right=status_right,
                   style=Style(; bg=tstyle(:border).fg))
  render(sbar, status_rect, buf)
end

# ── Tab renderers ─────────────────────────────────────────────────────

function render_chat!(m::ProscaModel, rect::Rect, buf::Buffer)
  m.scroll.block = Block(title="Chat", border_style=tstyle(:border),
                         title_style=tstyle(:primary, bold=true))
  render(m.scroll, rect, buf)
end

function render_repl_log!(m::ProscaModel, rect::Rect, buf::Buffer)
  label = isempty(AGENTS) ? "REPL" : "REPL ($(default_agent().id))"
  m.repl_scroll.block = Block(title=label, border_style=tstyle(:border),
                               title_style=tstyle(:accent, bold=true))
  render(m.repl_scroll, rect, buf)
end

function render_help!(rect::Rect, buf::Buffer)
  help_lines = [
    "Caesar TUI - Keyboard Shortcuts",
    "",
    "  Ctrl+N      Next tab",
    "  Ctrl+P      Previous tab",
    "  Ctrl+Q      Quit",
    "  Tab         Autocomplete (;commands, /skills)",
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

function render_agents!(rect::Rect, buf::Buffer)
  if isempty(AGENTS)
    lines = ["No agents loaded.", "", "Create agents via the GUI or agents/ directory."]
  else
    lines = String["Loaded Agents:", ""]
    for (id, agent) in AGENTS
      first_line = split(agent.personality, '\n')[1]
      push!(lines, "  $id")
      push!(lines, "    $first_line")
      n_skills = length(agent.skills)
      n_skills > 0 && push!(lines, "    $n_skills local skill$(n_skills > 1 ? "s" : "")")
      push!(lines, "")
    end
  end
  p = Paragraph(join(lines, "\n");
                block=Block(title="Agents", border_style=tstyle(:border),
                            title_style=tstyle(:primary, bold=true)),
                wrap=word_wrap)
  render(p, rect, buf)
end

# ── Launch ────────────────────────────────────────────────────────────

enable_markdown()

# Redirect stderr to the agent's REPL log so warnings don't corrupt the TUI
let agent = first(values(AGENTS))
  redirect_stderr(agent.repl_log)
end

let model = ProscaModel()
  push_chat!(model, "Caesar started", tstyle(:success, bold=true))
  push_chat!(model, "Brain: $HOME", tstyle(:text_dim))
  push_chat!(model, "Model: $(get(CONFIG, "llm", "not configured"))", tstyle(:text_dim))
  push_chat!(model, "Agents: $(join(keys(AGENTS), ", "))", tstyle(:text_dim))
  push_chat!(model, "Type a message and press Enter. ^N/^P to switch tabs.", tstyle(:text_dim))
  push_chat!(model, "", tstyle(:text))
  app(model; default_bindings=true)
end
