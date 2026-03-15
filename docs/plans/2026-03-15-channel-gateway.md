# Channel Gateway Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a channel gateway with Telegram adapter so Prosca can be reached remotely, with presence-based routing that falls back from GUI to Telegram after idle timeout.

**Architecture:** In-process gateway alongside existing Julia agent. A `PresenceRouter` decides whether to route approvals/notifications through the GUI or an external channel adapter. The channel adapter interface uses type-parameterized envelopes for dispatch. Only Telegram is implemented now.

**Tech Stack:** Julia, HTTP.jl (Telegram Bot API long polling), SQLite (topic mapping), JSON3

**Spec:** `docs/specs/2026-03-15-channel-gateway-design.md`

---

## File Structure

```
gateway/
├── gateway.jl          # Envelope types, ChannelAdapter abstract type, PresenceRouter
├── telegram_api.jl     # Low-level Telegram Bot API wrapper (getUpdates, sendMessage, etc.)
└── telegram.jl         # TelegramAdapter <: ChannelAdapter
```

**Modified files:**
- `events.jl` — Add `ToolApprovalRetracted` event
- `json_io.jl` — Integrate PresenceRouter, add `is_active` protocol, modify approval routing, gateway startup

---

## Chunk 1: Core Gateway Types

### Task 1: Envelope types and ChannelAdapter interface

**Files:**
- Create: `gateway/gateway.jl`

- [ ] **Step 1: Create `gateway/gateway.jl` with envelope types and adapter interface**

```julia
# gateway/gateway.jl — Channel gateway: envelope types, adapter interface, presence router

using Dates

# ── Envelope types (type-parameterized by channel symbol) ───────────

struct InboundEnvelope{C}
    sender_id::String
    text::String
    topic_id::String
    reply_to_id::Union{String,Nothing}
    raw::Dict
    received_at::DateTime
end

struct OutboundEnvelope{C}
    text::String
    topic_id::String
    reply_to_id::Union{String,Nothing}
    buttons::Vector{Tuple{String,String}}  # (label, callback_data) for inline keyboards
end

# Convenience constructors
OutboundEnvelope{C}(text::String, topic_id::String) where C =
    OutboundEnvelope{C}(text, topic_id, nothing, Tuple{String,String}[])

# ── Channel adapter interface ───────────────────────────────────────

abstract type ChannelAdapter end

# Lifecycle — gateway reference passed at start so adapter can call on_inbound
function start!(adapter::ChannelAdapter, gateway) end
function stop!(adapter::ChannelAdapter) end
is_connected(::ChannelAdapter) = false

# Messaging — send_message returns platform message ID (for retraction)
function send_message(adapter::ChannelAdapter, env::OutboundEnvelope)::String
    error("send_message not implemented for $(typeof(adapter))")
end

function retract_message(adapter::ChannelAdapter, message_id::String)
    error("retract_message not implemented for $(typeof(adapter))")
end
```

- [ ] **Step 2: Verify it loads without errors**

Run: `cd /Users/jake/Prosca && julia -e 'include("gateway/gateway.jl")'`
Expected: No errors, clean exit

- [ ] **Step 3: Commit**

```bash
git add gateway/gateway.jl
git commit -m "feat(gateway): add envelope types and channel adapter interface"
```

### Task 2: PresenceRouter

**Files:**
- Modify: `gateway/gateway.jl` (append to existing)
- Modify: `events.jl:24-27` (add ToolApprovalRetracted)

- [ ] **Step 1: Add `ToolApprovalRetracted` event to `events.jl`**

Add after the `ToolApproval` struct (line 27):

```julia
struct ToolApprovalRetracted
  id::UInt64
  reason::String  # e.g. "routed_to_telegram", "routed_to_gui"
end
```

- [ ] **Step 2: Verify events.jl loads**

Run: `cd /Users/jake/Prosca && julia -e 'include("events.jl"); println(fieldnames(ToolApprovalRetracted))'`
Expected: `(:id, :reason)`

- [ ] **Step 3: Add PresenceRouter and PendingApproval to `gateway/gateway.jl`**

Append to the file:

```julia
# ── Presence Router ─────────────────────────────────────────────────

mutable struct PendingApproval
    id::UInt64                          # matches ToolCallRequest.id
    tool_name::String
    args::String
    conversation_id::Union{String,Nothing}
    current_target::Symbol              # :gui or channel symbol (:telegram, etc.)
    telegram_message_id::Union{String,Nothing}
    lock::ReentrantLock
    response::Channel{ToolApproval}     # blocks until user responds
end

mutable struct PresenceRouter
    idle_threshold_mins::Int
    active_adapters::Vector{ChannelAdapter}
    pending_approvals::Dict{UInt64, PendingApproval}
    gui_io::Union{Function, Nothing}   # emit function for GUI, nothing if no GUI
    check_gui_active::Union{Function, Nothing}  # () -> Bool, queries GUI is_active
    _inbound_handler::Union{Function, Nothing}  # (InboundEnvelope) -> Nothing
end

PresenceRouter(; idle_threshold_mins=15) = PresenceRouter(
    idle_threshold_mins,
    ChannelAdapter[],
    Dict{UInt64, PendingApproval}(),
    nothing,
    nothing,
    nothing  # _inbound_handler
)

"""Return the channel symbol for an adapter (used by _send_approval_to_adapter)."""
channel_symbol(::ChannelAdapter) = :unknown

function register_adapter!(router::PresenceRouter, adapter::ChannelAdapter)
    push!(router.active_adapters, adapter)
end

function primary_adapter(router::PresenceRouter)::Union{ChannelAdapter, Nothing}
    isempty(router.active_adapters) ? nothing : first(router.active_adapters)
end

"""
    gui_is_active(router) -> Bool

Query the GUI for activity status. Returns false if no GUI is connected
or if the GUI doesn't respond.
"""
function gui_is_active(router::PresenceRouter)::Bool
    router.check_gui_active === nothing && return false
    try
        router.check_gui_active()
    catch
        false
    end
end

"""
    route_approval(router, request, inbox) -> Nothing

Route a tool approval request to GUI or channel adapter based on presence.
Blocks until the user responds. Puts the ToolApproval on inbox.
"""
function route_approval(router::PresenceRouter, request::ToolCallRequest, inbox::Channel;
                        conversation_id::Union{String,Nothing}=nothing)
    pa = PendingApproval(
        request.id, request.name, request.args, conversation_id,
        :gui, nothing, ReentrantLock(), Channel{ToolApproval}(1)
    )
    router.pending_approvals[request.id] = pa

    adapter = primary_adapter(router)

    if gui_is_active(router)
        # Send to GUI
        lock(pa.lock) do
            pa.current_target = :gui
        end
        if router.gui_io !== nothing
            router.gui_io(Dict("type" => "tool_call_request",
                              "id" => string(request.id),
                              "name" => request.name,
                              "args" => request.args);
                         conversation_id)
        end
    elseif adapter !== nothing
        # GUI not active, send to channel adapter
        _send_approval_to_adapter(router, pa, adapter)
    else
        # No adapter, send to GUI anyway (original behavior)
        lock(pa.lock) do
            pa.current_target = :gui
        end
        if router.gui_io !== nothing
            router.gui_io(Dict("type" => "tool_call_request",
                              "id" => string(request.id),
                              "name" => request.name,
                              "args" => request.args);
                         conversation_id)
        end
    end

    # Block until response
    approval = take!(pa.response)
    delete!(router.pending_approvals, request.id)
    put!(inbox, approval)
end

function _send_approval_to_adapter(router::PresenceRouter, pa::PendingApproval, adapter::ChannelAdapter)
    C = channel_symbol(adapter)
    env = OutboundEnvelope{C}(
        "Approval needed\nTool: $(pa.tool_name)\nArgs: $(pa.args)",
        "_approvals",
        nothing,
        [("Approve", "approve:$(pa.id)"),
         ("Deny", "deny:$(pa.id)"),
         ("Always", "always:$(pa.id)")]
    )
    lock(pa.lock) do
        msg_id = send_message(adapter, env)
        pa.telegram_message_id = msg_id
        pa.current_target = C
    end
end

"""
    resolve_approval(router, id, decision, from_target) -> Bool

Resolve a pending approval. Returns true if accepted, false if the approval
was already retracted from this target (stale response).
"""
function resolve_approval(router::PresenceRouter, id::UInt64, decision::Symbol, from_target::Symbol)::Bool
    pa = get(router.pending_approvals, id, nothing)
    pa === nothing && return false
    lock(pa.lock) do
        if pa.current_target != from_target
            return false  # stale — approval was retracted from this target
        end
        put!(pa.response, ToolApproval(id, decision))
        return true
    end
end

"""
    check_pending_approvals!(router)

Called periodically (every 60s). Checks if pending approvals need to be
migrated between GUI and channel adapter based on presence changes.
"""
function check_pending_approvals!(router::PresenceRouter)
    adapter = primary_adapter(router)
    gui_active = gui_is_active(router)

    for (id, pa) in router.pending_approvals
        lock(pa.lock) do
            C = adapter !== nothing ? channel_symbol(adapter) : :unknown
            if pa.current_target == :gui && !gui_active && adapter !== nothing
                # GUI went idle — retract from GUI, send to adapter
                if router.gui_io !== nothing
                    router.gui_io(Dict("type" => "tool_approval_retracted",
                                      "id" => pa.id,
                                      "reason" => "routed_to_telegram");
                                 pa.conversation_id)
                end
                _send_approval_to_adapter(router, pa, adapter)
            elseif pa.current_target == C && gui_active && adapter !== nothing
                # GUI came back — retract from Telegram, re-present in GUI
                if pa.telegram_message_id !== nothing
                    try retract_message(adapter, pa.telegram_message_id) catch end
                    pa.telegram_message_id = nothing
                end
                pa.current_target = :gui
                if router.gui_io !== nothing
                    router.gui_io(Dict("type" => "tool_call_request",
                                      "id" => string(pa.id),
                                      "name" => pa.tool_name,
                                      "args" => pa.args);
                                 pa.conversation_id)
                end
            end
        end
    end
end

"""
    route_notification(router, text, project_id)

Send a notification to the user via the best available channel.
"""
function route_notification(router::PresenceRouter, text::String;
                           project_id::Union{String,Nothing}=nothing,
                           routine_id::Union{String,Nothing}=nothing,
                           extra_gui_emit::Union{Function,Nothing}=nothing)
    adapter = primary_adapter(router)

    if gui_is_active(router) || adapter === nothing
        # Send to GUI
        if router.gui_io !== nothing
            d = Dict{String,Any}("type" => "notification", "text" => text)
            project_id !== nothing && (d["project_id"] = project_id)
            routine_id !== nothing && (d["routine_id"] = routine_id)
            router.gui_io(d)
        end
        # Run any extra GUI-side emit (e.g. unseen_count)
        extra_gui_emit !== nothing && extra_gui_emit()
    else
        # Send to channel adapter
        C = channel_symbol(adapter)
        topic = project_id !== nothing ? project_id : "_general"
        env = OutboundEnvelope{C}(text, topic)
        try send_message(adapter, env) catch e
            @warn "Failed to send notification to adapter" exception=e
            # Fallback to GUI
            if router.gui_io !== nothing
                d = Dict{String,Any}("type" => "notification", "text" => text)
                project_id !== nothing && (d["project_id"] = project_id)
                routine_id !== nothing && (d["routine_id"] = routine_id)
                router.gui_io(d)
            end
            extra_gui_emit !== nothing && extra_gui_emit()
        end
    end
end
```

- [ ] **Step 4: Verify gateway.jl loads with events.jl**

Run: `cd /Users/jake/Prosca && julia -e 'include("events.jl"); include("gateway/gateway.jl"); r = PresenceRouter(); println("ok: $(length(r.pending_approvals)) pending")'`
Expected: `ok: 0 pending`

- [ ] **Step 5: Commit**

```bash
git add gateway/gateway.jl events.jl
git commit -m "feat(gateway): add PresenceRouter with approval routing and migration"
```

---

## Chunk 2: Telegram Bot API Wrapper

### Task 3: Low-level Telegram API

**Files:**
- Create: `gateway/telegram_api.jl`

This is a thin wrapper around the Telegram Bot API HTTP endpoints. No adapter logic — just HTTP calls.

- [ ] **Step 1: Create `gateway/telegram_api.jl`**

```julia
# gateway/telegram_api.jl — Low-level Telegram Bot API wrapper

using HTTP, JSON3
using Logging

const TELEGRAM_API_BASE = "https://api.telegram.org/bot"

struct TelegramAPIError <: Exception
    code::Int
    description::String
end

Base.showerror(io::IO, e::TelegramAPIError) = print(io, "Telegram API error $(e.code): $(e.description)")

"""
    telegram_request(token, method, params) -> JSON3.Object

Make a request to the Telegram Bot API. Returns the `result` field on success.
"""
function telegram_request(token::String, method::String, params::Dict=Dict{String,Any}())
    url = "$(TELEGRAM_API_BASE)$(token)/$(method)"
    body = JSON3.write(params)
    resp = HTTP.post(url,
        ["Content-Type" => "application/json"],
        body;
        status_exception=false,
        connect_timeout=10,
        readtimeout=35)  # > long poll timeout (30s)

    parsed = JSON3.read(String(resp.body))
    if !get(parsed, :ok, false)
        throw(TelegramAPIError(
            get(parsed, :error_code, resp.status),
            string(get(parsed, :description, "Unknown error"))
        ))
    end
    get(parsed, :result, nothing)
end

# ── Specific API methods ────────────────────────────────────────────

function tg_get_updates(token::String; offset::Int=0, timeout::Int=30)
    params = Dict{String,Any}("timeout" => timeout, "allowed_updates" => ["message", "callback_query"])
    offset > 0 && (params["offset"] = offset)
    telegram_request(token, "getUpdates", params)
end

function tg_send_message(token::String, chat_id::Int64, text::String;
                         message_thread_id::Union{Int64,Nothing}=nothing,
                         parse_mode::String="MarkdownV2",
                         reply_to_message_id::Union{Int64,Nothing}=nothing,
                         reply_markup=nothing)
    params = Dict{String,Any}("chat_id" => chat_id, "text" => text, "parse_mode" => parse_mode)
    message_thread_id !== nothing && (params["message_thread_id"] = message_thread_id)
    reply_to_message_id !== nothing && (params["reply_to_message_id"] = reply_to_message_id)
    reply_markup !== nothing && (params["reply_markup"] = reply_markup)
    telegram_request(token, "sendMessage", params)
end

function tg_delete_message(token::String, chat_id::Int64, message_id::Int64)
    telegram_request(token, "deleteMessage",
        Dict{String,Any}("chat_id" => chat_id, "message_id" => message_id))
end

function tg_answer_callback_query(token::String, callback_query_id::String; text::String="")
    params = Dict{String,Any}("callback_query_id" => callback_query_id)
    !isempty(text) && (params["text"] = text)
    telegram_request(token, "answerCallbackQuery", params)
end

function tg_create_forum_topic(token::String, chat_id::Int64, name::String)
    telegram_request(token, "createForumTopic",
        Dict{String,Any}("chat_id" => chat_id, "name" => name))
end

function tg_get_forum_topic_list(token::String, chat_id::Int64)
    # Note: Telegram doesn't have a direct "list topics" endpoint.
    # We track topics ourselves in SQLite after creating them.
    nothing
end

"""
    tg_escape_markdown(text) -> String

Escape special characters for Telegram MarkdownV2.
"""
function tg_escape_markdown(text::String)::String
    # Characters that must be escaped in MarkdownV2
    special = raw"_*[]()~`>#+-=|{}.!"
    result = IOBuffer()
    for c in text
        c in special && write(result, '\\')
        write(result, c)
    end
    String(take!(result))
end

"""
    tg_split_message(text; limit=4096) -> Vector{String}

Split a long message at paragraph boundaries to stay under Telegram's limit.
"""
function tg_split_message(text::String; limit::Int=4096)::Vector{String}
    ncodeunits(text) <= limit && return [text]
    chunks = String[]
    remaining = text
    while ncodeunits(remaining) > limit
        # Find a safe byte boundary at or before `limit`
        safe_end = prevind(remaining, min(ncodeunits(remaining), limit) + 1)
        window = remaining[1:safe_end]
        # Find last paragraph break before limit
        cut = findlast("\n\n", window)
        if cut === nothing
            # No paragraph break — find last newline
            cut_pos = findlast('\n', window)
            if cut_pos === nothing
                cut_pos = safe_end  # Hard cut as last resort
            end
        else
            cut_pos = last(cut)
        end
        push!(chunks, remaining[1:cut_pos])
        remaining = lstrip(remaining[nextind(remaining, cut_pos):end])
    end
    !isempty(remaining) && push!(chunks, remaining)
    chunks
end
```

- [ ] **Step 2: Verify it loads**

Run: `cd /Users/jake/Prosca && julia -e 'include("gateway/telegram_api.jl"); println(tg_escape_markdown("hello *world* [test]")); println(length(tg_split_message(repeat("x", 5000))))'`
Expected:
```
hello \*world\* \[test\]
2
```

- [ ] **Step 3: Commit**

```bash
git add gateway/telegram_api.jl
git commit -m "feat(gateway): add Telegram Bot API wrapper"
```

---

## Chunk 3: Telegram Adapter

### Task 4: TelegramAdapter struct and lifecycle

**Files:**
- Create: `gateway/telegram.jl`

- [ ] **Step 1: Create `gateway/telegram.jl` with struct, start!, stop!, polling loop**

```julia
# gateway/telegram.jl — Telegram channel adapter

include("telegram_api.jl")

using SQLite
using Dates
using Logging

mutable struct TelegramAdapter <: ChannelAdapter
    bot_token::String
    chat_id::Int64
    owner_id::Int64
    topic_map::Dict{String, Int64}         # project_id -> thread_id
    reverse_topic_map::Dict{Int64, String} # thread_id -> project_id
    approvals_topic_id::Int64
    gateway::Union{PresenceRouter, Nothing}
    poll_task::Union{Task, Nothing}
    poll_offset::Int
    message_cache::Dict{String, DateTime}  # "chat_id:msg_id" -> received_at (dedup)
    db::SQLite.DB
    running::Ref{Bool}
end

function TelegramAdapter(; bot_token::String, chat_id::Int64, owner_id::Int64, db::SQLite.DB)
    TelegramAdapter(
        bot_token, chat_id, owner_id,
        Dict{String,Int64}(), Dict{Int64,String}(),
        0, nothing, nothing, 0,
        Dict{String,DateTime}(), db, Ref(false)
    )
end

function start!(adapter::TelegramAdapter, gateway::PresenceRouter)
    adapter.gateway = gateway
    adapter.running[] = true

    # Ensure channel_topics table exists
    SQLite.execute(adapter.db, """
        CREATE TABLE IF NOT EXISTS channel_topics (
            project_id TEXT NOT NULL,
            channel TEXT NOT NULL,
            topic_thread_id INTEGER NOT NULL,
            chat_id INTEGER NOT NULL,
            PRIMARY KEY (project_id, channel)
        )
    """)

    # Load existing topic mapping
    _load_topic_map!(adapter)

    # Sync projects to topics
    _sync_project_topics!(adapter)

    # Start long-polling loop
    adapter.poll_task = @async _poll_loop(adapter)
    @info "Telegram adapter started (chat_id=$(adapter.chat_id))"
end

function stop!(adapter::TelegramAdapter)
    adapter.running[] = false
    adapter.gateway = nothing
    if adapter.poll_task !== nothing
        # The poll loop will exit on next iteration
        adapter.poll_task = nothing
    end
    @info "Telegram adapter stopped"
end

is_connected(adapter::TelegramAdapter) = adapter.running[] && adapter.poll_task !== nothing
channel_symbol(::TelegramAdapter) = :telegram

# ── Topic mapping ───────────────────────────────────────────────────

function _load_topic_map!(adapter::TelegramAdapter)
    empty!(adapter.topic_map)
    empty!(adapter.reverse_topic_map)
    rows = SQLite.DBInterface.execute(adapter.db,
        "SELECT project_id, topic_thread_id FROM channel_topics WHERE channel='telegram' AND chat_id=?",
        (adapter.chat_id,)) |> SQLite.rowtable
    for r in rows
        adapter.topic_map[r.project_id] = r.topic_thread_id
        adapter.reverse_topic_map[r.topic_thread_id] = r.project_id
    end
    # Load approvals topic
    rows = SQLite.DBInterface.execute(adapter.db,
        "SELECT topic_thread_id FROM channel_topics WHERE channel='telegram' AND project_id='_approvals' AND chat_id=?",
        (adapter.chat_id,)) |> SQLite.rowtable
    if !isempty(rows)
        adapter.approvals_topic_id = rows[1].topic_thread_id
    end
end

function _sync_project_topics!(adapter::TelegramAdapter)
    # Create approvals topic if missing
    if adapter.approvals_topic_id == 0
        try
            result = tg_create_forum_topic(adapter.bot_token, adapter.chat_id, "Approvals")
            tid = result.message_thread_id
            adapter.approvals_topic_id = tid
            SQLite.execute(adapter.db, """
                INSERT OR REPLACE INTO channel_topics (project_id, channel, topic_thread_id, chat_id)
                VALUES ('_approvals', 'telegram', ?, ?)
            """, (tid, adapter.chat_id))
        catch e
            @warn "Failed to create Approvals topic" exception=e
        end
    end

    # Create topics for projects that don't have one yet
    projects = SQLite.DBInterface.execute(adapter.db,
        "SELECT id, name FROM projects") |> SQLite.rowtable
    for proj in projects
        pid = proj.id
        haskey(adapter.topic_map, pid) && continue
        try
            result = tg_create_forum_topic(adapter.bot_token, adapter.chat_id, proj.name)
            tid = result.message_thread_id
            adapter.topic_map[pid] = tid
            adapter.reverse_topic_map[tid] = pid
            SQLite.execute(adapter.db, """
                INSERT OR REPLACE INTO channel_topics (project_id, channel, topic_thread_id, chat_id)
                VALUES (?, 'telegram', ?, ?)
            """, (pid, tid, adapter.chat_id))
        catch e
            @warn "Failed to create topic for project $(proj.name)" exception=e
        end
    end
end

"""
    ensure_project_topic!(adapter, project_id, project_name) -> Int64

Create a forum topic for a project if it doesn't exist yet. Returns the thread_id.
"""
function ensure_project_topic!(adapter::TelegramAdapter, project_id::String, project_name::String)::Int64
    haskey(adapter.topic_map, project_id) && return adapter.topic_map[project_id]
    result = tg_create_forum_topic(adapter.bot_token, adapter.chat_id, project_name)
    tid = result.message_thread_id
    adapter.topic_map[project_id] = tid
    adapter.reverse_topic_map[tid] = project_id
    SQLite.execute(adapter.db, """
        INSERT OR REPLACE INTO channel_topics (project_id, channel, topic_thread_id, chat_id)
        VALUES (?, 'telegram', ?, ?)
    """, (project_id, tid, adapter.chat_id))
    tid
end

# ── Messaging ───────────────────────────────────────────────────────

function send_message(adapter::TelegramAdapter, env::OutboundEnvelope{:telegram})::String
    # Resolve topic_id to thread_id
    thread_id = if env.topic_id == "_approvals"
        adapter.approvals_topic_id > 0 ? adapter.approvals_topic_id : nothing
    else
        get(adapter.topic_map, env.topic_id, nothing)
    end

    # Build reply markup for inline keyboard buttons
    reply_markup = if !isempty(env.buttons)
        Dict("inline_keyboard" => [[Dict("text" => label, "callback_data" => data)
                                     for (label, data) in env.buttons]])
    else
        nothing
    end

    # Split long messages
    chunks = tg_split_message(env.text)
    last_msg_id = ""

    for (i, chunk) in enumerate(chunks)
        # Only add buttons to last chunk
        markup = (i == length(chunks)) ? reply_markup : nothing
        reply_to = if env.reply_to_id !== nothing
            tryparse(Int64, env.reply_to_id)
        else
            nothing
        end

        try
            result = tg_send_message(adapter.bot_token, adapter.chat_id, chunk;
                message_thread_id=thread_id,
                reply_to_message_id=reply_to,
                reply_markup=markup,
                parse_mode="")  # Use plain text to avoid escaping issues
            last_msg_id = string(result.message_id)
        catch e
            if e isa TelegramAPIError && e.code == 409
                @warn "Telegram conflict (409) — another instance polling?" exception=e
                sleep(5)
            else
                rethrow()
            end
        end
    end

    last_msg_id
end

function retract_message(adapter::TelegramAdapter, message_id::String)
    mid = tryparse(Int64, message_id)
    mid === nothing && return
    try
        tg_delete_message(adapter.bot_token, adapter.chat_id, mid)
    catch e
        @warn "Failed to retract Telegram message $message_id" exception=e
    end
end

# ── Long polling loop ───────────────────────────────────────────────

function _poll_loop(adapter::TelegramAdapter)
    backoff = 1
    while adapter.running[]
        try
            updates = tg_get_updates(adapter.bot_token; offset=adapter.poll_offset, timeout=30)
            backoff = 1  # reset on success

            # Evict stale dedup cache entries (older than 5 min)
            cutoff = now(Dates.UTC) - Dates.Minute(5)
            filter!(((k, v),) -> v > cutoff, adapter.message_cache)

            updates === nothing && continue
            for update in updates
                adapter.poll_offset = get(update, :update_id, 0) + 1
                _handle_update(adapter, update)
            end
        catch e
            if e isa TelegramAPIError && e.code == 409
                @warn "Telegram 409 conflict — backing off $(backoff)s"
            else
                @warn "Telegram poll error — backing off $(backoff)s" exception=e
            end
            sleep(min(backoff, 30))
            backoff = min(backoff * 2, 30)
        end
    end
end

function _handle_update(adapter::TelegramAdapter, update)
    if haskey(update, :callback_query)
        _handle_callback_query(adapter, update.callback_query)
    elseif haskey(update, :message)
        _handle_message(adapter, update.message)
    end
end

function _handle_callback_query(adapter::TelegramAdapter, cq)
    # Answer the callback to remove the loading indicator
    try tg_answer_callback_query(adapter.bot_token, string(cq.id)) catch end

    # Access control
    sender_id = get(cq, :from, Dict()) |> d -> get(d, :id, 0)
    sender_id == adapter.owner_id || return

    data = string(get(cq, :data, ""))
    # Parse "approve:12345" / "deny:12345" / "always:12345"
    m = match(r"^(approve|deny|always):(\d+)$", data)
    m === nothing && return

    action = m.captures[1]
    approval_id = tryparse(UInt64, m.captures[2])
    approval_id === nothing && return

    decision = if action == "approve"
        :allow
    elseif action == "always"
        :always
    else
        :deny
    end

    adapter.gateway !== nothing && resolve_approval(adapter.gateway, approval_id, decision, :telegram)
end

function _handle_message(adapter::TelegramAdapter, msg)
    # Access control
    sender_id = get(msg, :from, Dict()) |> d -> get(d, :id, 0)
    sender_id == adapter.owner_id || return

    # Dedup
    msg_id = get(msg, :message_id, 0)
    dedup_key = "$(adapter.chat_id):$(msg_id)"
    haskey(adapter.message_cache, dedup_key) && return
    adapter.message_cache[dedup_key] = now(Dates.UTC)

    text = string(get(msg, :text, ""))
    isempty(text) && return

    # Resolve thread to project
    thread_id = get(msg, :message_thread_id, nothing)
    project_id = thread_id !== nothing ? get(adapter.reverse_topic_map, thread_id, nothing) : nothing

    # Build inbound envelope and deliver to router
    if adapter.gateway !== nothing
        env = InboundEnvelope{:telegram}(
            string(sender_id), text,
            project_id !== nothing ? project_id : "_general",
            nothing, Dict{String,Any}("message" => msg),
            now(Dates.UTC)
        )
        on_inbound(adapter.gateway, env)
    end
end

"""
    on_inbound(router, envelope)

Handle an inbound message from a channel adapter. Creates a new agent task.
This is called by the adapter when a message arrives from Telegram.
"""
function on_inbound(router::PresenceRouter, env::InboundEnvelope{:telegram})
    # This function will be connected to the agent dispatch in json_io.jl integration.
    # For now it's a hook point — the actual agent dispatch is wired during integration.
    if router._inbound_handler !== nothing
        router._inbound_handler(env)
    else
        @warn "No inbound handler registered on PresenceRouter for Telegram message"
    end
end
```

**Note:** The `_inbound_handler` field and `channel_symbol` function were already added to `PresenceRouter` in Task 2 Step 3, so no additional changes to `gateway.jl` are needed here.

- [ ] **Step 2: Verify telegram.jl loads with its dependencies**

Run: `cd /Users/jake/Prosca && julia -e 'include("events.jl"); include("gateway/gateway.jl"); include("gateway/telegram.jl"); println("ok")'`
Expected: `ok`

- [ ] **Step 3: Commit**

```bash
git add gateway/telegram.jl
git commit -m "feat(gateway): add TelegramAdapter with long polling and approval callbacks"
```

---

## Chunk 4: Integration with json_io.jl

### Task 5: Wire up the gateway to the existing sidecar loop

**Files:**
- Modify: `json_io.jl`

This is the most delicate task — it modifies the existing message loop to integrate the PresenceRouter.

- [ ] **Step 1: Add gateway includes and initialization after the scheduler include**

At the top of `json_io.jl`, after line 11 (`using .Scheduler`), add:

```julia
include("gateway/gateway.jl")
include("gateway/telegram.jl")
```

- [ ] **Step 2: Add gateway initialization after the `SCHEDULER_TIMER` (line 704)**

After line 704, add router creation, adapter construction (if configured), and the approval check timer:

```julia
# ── Gateway setup ───────────────────────────────────────────────────

const ROUTER = PresenceRouter(;
    idle_threshold_mins=get(get(CONFIG, "gateway", Dict()), "idle_threshold_mins", 15)
)

# Wire the router's GUI emit function to our emit()
ROUTER.gui_io = (d; conversation_id=nothing) -> emit(d; conversation_id)

# Wire GUI activity check — uses is_active protocol
# For json_io (sidecar mode), we track activity via last_user_activity_at
ROUTER.check_gui_active = () -> begin
    idle_secs = Dates.value(now(Dates.UTC) - last_user_activity_at[]) / 1000
    idle_secs < ROUTER.idle_threshold_mins * 60
end

# Set up inbound handler for Telegram messages → agent dispatch
ROUTER._inbound_handler = (env::InboundEnvelope) -> begin
    text = env.text
    conv_id = "tg-$(env.topic_id)"
    conv = get_gui_conversation(conv_id)
    @async begin
        lock(AGENT_LOCK)
        try
            run_agent(text, conv.outbox, conv.inbox;
                      session_history=conv.history, auto_allowed=conv.auto_allowed,
                      conversation_id=conv_id)
        finally
            unlock(AGENT_LOCK)
        end
    end
    # Drain agent events and send back to Telegram
    @async begin
        adapter = primary_adapter(ROUTER)
        adapter === nothing && return
        while true
            event = take!(conv.outbox)
            if event isa AgentMessage
                try
                    out = OutboundEnvelope{:telegram}(event.text, env.topic_id)
                    send_message(adapter, out)
                catch e
                    @warn "Failed to send agent response to Telegram" exception=e
                end
            elseif event isa ToolCallRequest
                # Route through presence router
                @async route_approval(ROUTER, event, conv.inbox; conversation_id=conv_id)
            elseif event isa ToolResult
                # Optionally send tool results to Telegram for visibility
            elseif event isa AgentDone
                break
            end
        end
    end
end

# Initialize Telegram adapter if configured
let gw_config = get(CONFIG, "gateway", nothing)
    if gw_config !== nothing
        tg_config = get(gw_config, "telegram", nothing)
        if tg_config !== nothing
            bot_token = string(get(tg_config, "bot_token", ""))
            chat_id = get(tg_config, "chat_id", 0)
            owner_id = get(tg_config, "owner_id", 0)
            if !isempty(bot_token) && chat_id != 0 && owner_id != 0
                adapter = TelegramAdapter(; bot_token, chat_id=Int64(chat_id), owner_id=Int64(owner_id), db=DB)
                register_adapter!(ROUTER, adapter)
                try
                    start!(adapter, ROUTER)
                    @info "Telegram gateway active"
                catch e
                    @warn "Failed to start Telegram adapter" exception=e
                end
            end
        end
    end
end

# Timer to check pending approval migrations (every 60s)
const APPROVAL_CHECK_TIMER = Timer(t -> begin
    try check_pending_approvals!(ROUTER) catch e
        @warn "Approval check error" exception=e
    end
end, 60; interval=60)
```

- [ ] **Step 3: Modify the `handle_events` function to route approvals through the router**

Replace the `ToolCallRequest` case in `handle_events` (line 49-50) to check if the router has adapters. If it does, route through the router instead of emitting directly:

In `handle_events`, change the `ToolCallRequest` branch from:

```julia
    elseif event isa ToolCallRequest
      emit(Dict("type" => "tool_call_request", "id" => string(event.id), "name" => event.name, "args" => event.args); conversation_id)
```

To:

```julia
    elseif event isa ToolCallRequest
      if !isempty(ROUTER.active_adapters)
        # Route through presence router (handles GUI vs Telegram)
        @async route_approval(ROUTER, event, _current_inbox(conversation_id); conversation_id)
      else
        # No gateway configured — direct to GUI as before
        emit(Dict("type" => "tool_call_request", "id" => string(event.id), "name" => event.name, "args" => event.args); conversation_id)
      end
```

And add a helper to resolve the inbox for a conversation_id:

```julia
function _current_inbox(conversation_id::Union{String,Nothing})
    cid = conversation_id === nothing ? "default" : conversation_id
    get_gui_conversation(cid).inbox
end
```

- [ ] **Step 4: Modify the `tool_approval` handler to check ownership**

In the main loop's `tool_approval` handler (around line 746), change it to check with the router first:

From:
```julia
    elseif msg_type == "tool_approval"
      id = parse(UInt64, string(get(msg, :id, "0")))
      decision_str = string(get(msg, :decision, "deny"))
      decision = if decision_str == "allow"
        :allow
      elseif decision_str == "always"
        :always
      else
        :deny
      end
      conv = get_gui_conversation(conv_id === nothing ? "default" : conv_id)
      put!(conv.inbox, ToolApproval(id, decision))
```

To:
```julia
    elseif msg_type == "tool_approval"
      id = parse(UInt64, string(get(msg, :id, "0")))
      decision_str = string(get(msg, :decision, "deny"))
      decision = if decision_str == "allow"
        :allow
      elseif decision_str == "always"
        :always
      else
        :deny
      end
      if !isempty(ROUTER.active_adapters)
        # Route through router (checks ownership, handles retraction race)
        resolve_approval(ROUTER, id, decision, :gui)
      else
        # No gateway — direct as before
        conv = get_gui_conversation(conv_id === nothing ? "default" : conv_id)
        put!(conv.inbox, ToolApproval(id, decision))
      end
```

- [ ] **Step 5: Add `is_active` handler to the main loop**

In the main message loop (around line 808, before the `else` catch-all), add:

```julia
    elseif msg_type == "is_active_response"
      # GUI responds to is_active query — currently handled synchronously
      # via check_gui_active callback, so this is a no-op.
      # Future: could support async is_active if needed.
```

- [ ] **Step 6: Route notifications through the router**

In `_run_routine` (lines 637-642), change the notification emit to go through the router. Preserve `routine_id` and the `unseen_count` emit that follows:

From:
```julia
  if notable == 1
    emit(Dict("type" => "notification", "text" => clean_result,
              "project_id" => routine.project_id, "routine_id" => routine.id))
    count = Scheduler.unseen_notable_count(DB)
    emit(Dict("type" => "unseen_count", "count" => count))
  end
```

To:
```julia
  if notable == 1
    route_notification(ROUTER, clean_result;
        project_id=routine.project_id,
        routine_id=routine.id,
        extra_gui_emit=() -> begin
            count = Scheduler.unseen_notable_count(DB)
            emit(Dict("type" => "unseen_count", "count" => count))
        end)
  end
```

Similarly in `_run_project_checkin` (lines 694-698):

From:
```julia
  if notable == 1
    emit(Dict("type" => "notification", "text" => clean_result, "project_id" => project.id))
    count = Scheduler.unseen_notable_count(DB)
    emit(Dict("type" => "unseen_count", "count" => count))
  end
```

To:
```julia
  if notable == 1
    route_notification(ROUTER, clean_result;
        project_id=project.id,
        extra_gui_emit=() -> begin
            count = Scheduler.unseen_notable_count(DB)
            emit(Dict("type" => "unseen_count", "count" => count))
        end)
  end
```

- [ ] **Step 7: Hook project creation to create Telegram topics at runtime**

In `handle_project_create` (around line 311, after the `SQLite.execute` INSERT), add:

```julia
  # Create Telegram topic for new project if gateway is active
  adapter = primary_adapter(ROUTER)
  if adapter !== nothing && adapter isa TelegramAdapter
      try ensure_project_topic!(adapter, id, name) catch e
          @warn "Failed to create Telegram topic for new project" exception=e
      end
  end
```

- [ ] **Step 8: Add conversation queuing for Telegram topics**

Add a tracking dict after the `ROUTER` setup to prevent concurrent agent runs per Telegram topic:

```julia
const TELEGRAM_ACTIVE_CONVERSATIONS = Dict{String, Bool}()  # topic_id -> is_running
const TELEGRAM_MESSAGE_QUEUE = Dict{String, Vector{InboundEnvelope}}()  # topic_id -> queued messages
```

Then update the `_inbound_handler` to check and queue:

Replace the `ROUTER._inbound_handler` closure's opening lines with:

```julia
ROUTER._inbound_handler = (env::InboundEnvelope) -> begin
    text = env.text
    topic = env.topic_id
    conv_id = "tg-$(topic)"

    # Queue if a conversation is already running for this topic
    if get(TELEGRAM_ACTIVE_CONVERSATIONS, topic, false)
        queue = get!(TELEGRAM_MESSAGE_QUEUE, topic) do; InboundEnvelope[] end
        push!(queue, env)
        adapter = primary_adapter(ROUTER)
        if adapter !== nothing
            try send_message(adapter, OutboundEnvelope{channel_symbol(adapter)}(
                "Message queued — I'll get to it when the current task finishes.", topic))
            catch end
        end
        return
    end

    TELEGRAM_ACTIVE_CONVERSATIONS[topic] = true
    conv = get_gui_conversation(conv_id)
```

And at the end of the drain `@async` block, after the `AgentDone` break, add:

```julia
        # Process queued messages for this topic
        TELEGRAM_ACTIVE_CONVERSATIONS[topic] = false
        queue = get(TELEGRAM_MESSAGE_QUEUE, topic, nothing)
        if queue !== nothing && !isempty(queue)
            next_env = popfirst!(queue)
            ROUTER._inbound_handler(next_env)
        end
```

- [ ] **Step 9: Verify the modified json_io.jl parses without syntax errors**

Run: `cd /Users/jake/Prosca && julia -e 'try; include("json_io.jl"); catch e; println(sprint(showerror, e)); end' 2>&1 | head -5`

This will fail to fully start (no stdin, no MCP servers), but should parse without syntax errors. Look for `SyntaxError` or `UndefVarError` in the output — those indicate problems. Connection errors or EOF are expected.

- [ ] **Step 10: Commit**

```bash
git add json_io.jl
git commit -m "feat(gateway): integrate PresenceRouter into json_io sidecar loop"
```

---

## Chunk 5: Manual Testing & Config

### Task 6: Documentation and config setup

**Files:**
- Modify: `config.yaml` (user action — not automated)

- [ ] **Step 1: Document the Telegram bot setup steps**

Create a brief setup section in the spec or as a comment in config.yaml. The user needs to:

1. Message @BotFather on Telegram → `/newbot` → get bot token
2. Create a Telegram group, enable "Topics" in group settings
3. Add the bot to the group as admin
4. Get the group's `chat_id` (send a message, then check `https://api.telegram.org/bot<TOKEN>/getUpdates`)
5. Get your own Telegram user ID (message @userinfobot)
6. Add to `config.yaml`:

```yaml
gateway:
  idle_threshold_mins: 15
  telegram:
    bot_token: "YOUR_BOT_TOKEN"
    chat_id: -100YOUR_CHAT_ID
    owner_id: YOUR_USER_ID
```

- [ ] **Step 2: Test end-to-end with real Telegram bot**

1. Start Prosca with the GUI: `julia json_io.jl` (or via Tauri)
2. Send a message from Telegram in the group → should appear as agent conversation
3. Wait 15 min (or temporarily set `idle_threshold_mins: 1`) → approvals should route to Telegram
4. Test approve/deny/always buttons
5. Test notifications from routines appearing in Telegram

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "feat(gateway): complete Telegram gateway integration"
```
