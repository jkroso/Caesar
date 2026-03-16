# gateway/gateway.jl — Channel gateway: envelope types, adapter interface, presence router

@use Dates

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
    return lock(pa.lock) do
        if pa.current_target != from_target
            false  # stale — approval was retracted from this target
        else
            put!(pa.response, ToolApproval(id, decision))
            true
        end
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
    route_notification(router, text; project_id, routine_id, extra_gui_emit)

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
