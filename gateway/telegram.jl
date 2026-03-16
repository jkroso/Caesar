# gateway/telegram.jl — Telegram channel adapter

@use "./telegram_api"...
@use SQLite
@use Dates
@use Logging

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

channel_symbol(::TelegramAdapter) = :telegram

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
        adapter.poll_task = nothing
    end
    @info "Telegram adapter stopped"
end

is_connected(adapter::TelegramAdapter) = adapter.running[] && adapter.poll_task !== nothing

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
    if router._inbound_handler !== nothing
        router._inbound_handler(env)
    else
        @warn "No inbound handler registered on PresenceRouter for Telegram message"
    end
end
