# Channel Gateway Design

**Date:** 2026-03-15
**Status:** Approved

## Overview

A channel gateway for Prosca that enables bidirectional communication via external messaging platforms (starting with Telegram). The agent can receive queries from the user when away from the computer, and proactively send notifications and approval requests. Runs in-process alongside the Julia agent, using Telegram long polling for sleep/wake resilience.

## Key Decisions

- **In-process gateway** — no separate process or HTTP server. The gateway is another interface alongside GUI/TUI/CLI.
- **Channel adapter interface** — abstract layer so future channels (Discord, Slack) can be added without modifying core code. Only Telegram implemented now.
- **Type-parameterized envelopes** — `InboundEnvelope{C}` / `OutboundEnvelope{C}` where `C` is a symbol (`:telegram`). Enables dispatch-based routing and allows external modules to add new channel types.
- **Presence-based routing** — GUI gets priority. After 15 min idle (configurable), falls back to Telegram.
- **GUI owns activity tracking** — the agent queries the GUI with `is_active` (passing the threshold), rather than the GUI reporting every interaction.
- **Blocking approvals** — agent waits indefinitely on Telegram for approve/deny. No timeouts, no auto-deny.
- **Telegram forum topics** — one topic per Prosca project + a dedicated Approvals topic.

## Channel Adapter Interface

```julia
abstract type ChannelAdapter end

# Lifecycle — gateway reference passed at start so adapter can emit inbound messages
start!(adapter::ChannelAdapter, gateway::PresenceRouter)
stop!(adapter::ChannelAdapter)
is_connected(adapter::ChannelAdapter)::Bool

# Messaging — send_message returns the platform message ID (for retraction)
send_message(adapter::ChannelAdapter, env::OutboundEnvelope)::String
retract_message(adapter::ChannelAdapter, message_id::String)

# Adapters call on_inbound(gateway, envelope) to deliver messages to the router
```

The gateway reference is stored by the adapter at `start!` time and used to call `on_inbound`. This avoids a separate registration mechanism.

## Envelope Types

```julia
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
```

`C` is a symbol (e.g. `:telegram`, `:discord`). Method dispatch on the type parameter replaces branching on a channel field, and allows external modules to define new channel types by adding methods.

## Presence Router

Decides whether to route messages/approvals through the GUI or the gateway.

```julia
mutable struct PresenceRouter
    idle_threshold_mins::Int
    active_adapters::Vector{ChannelAdapter}
    pending_approvals::Dict{UInt64, PendingApproval}  # keyed by ToolCallRequest.id
end

mutable struct PendingApproval
    id::UInt64                          # matches ToolCallRequest.id / ToolApproval.id
    tool_name::String
    args::String
    conversation_id::String
    current_target::Symbol              # :gui or :telegram
    telegram_message_id::Union{String,Nothing}  # for retraction
    lock::ReentrantLock                 # held when checking/changing current_target
    response::Channel{ToolApproval}     # blocks until user responds
end
```

### Bridge to Existing Approval Flow

The existing `_run_agent` in `main.jl` uses `outbox`/`inbox` channels with `ToolCallRequest` (id::UInt64) and `ToolApproval` (id::UInt64, decision::Symbol). The router wraps this flow:

1. When `_run_agent` puts a `ToolCallRequest` on the outbox, the interface layer (json_io.jl) intercepts it and calls `route_approval(router, request, outbox, inbox)`
2. The router creates a `PendingApproval` with a `Channel{ToolApproval}` and routes to GUI or Telegram
3. When the user responds (from either side), the router constructs a `ToolApproval` with the original `UInt64` id and the decision symbol, then puts it on the `inbox` channel
4. `_run_agent` receives the `ToolApproval` via `take!(inbox)` exactly as before — it doesn't know about the router

**`:always` handling:** Telegram inline keyboard offers three buttons: `[Approve] [Deny] [Always]`. The `:always` decision is supported — it adds the tool to `auto_allowed` the same way the GUI does today.

### GUI Activity Check

The router queries the GUI via the JSON protocol:

```json
// Agent -> GUI
{"type": "is_active", "idle_threshold_mins": 15}

// GUI -> Agent
{"type": "is_active_response", "active": true}
```

The GUI tracks `last_interaction_at` internally and responds based on the threshold passed in the query. If the GUI process is not running, the router treats it as inactive.

### Approval Flow

1. Agent needs tool approval → `_run_agent` puts `ToolCallRequest` on outbox
2. Interface layer calls `route_approval(router, request, outbox, inbox)`
3. Router queries GUI: `is_active`
4. **GUI active**: send approval to GUI as today, store `current_target = :gui`
5. A timer checks `is_active` every 60s for any pending approvals where `current_target == :gui`
6. **GUI goes idle**: emit `tool_approval_retracted` to GUI, send to Telegram, store `telegram_message_id` from `send_message` return value, update `current_target = :telegram`
7. The same 60s timer also checks for pending approvals where `current_target == :telegram` — if GUI becomes active again, retract from Telegram (using stored `telegram_message_id`) and re-present in GUI
8. **Race condition prevention**: the router holds a lock on each `PendingApproval`. Before processing any response (from GUI or Telegram), it acquires the lock and checks `current_target`. If the response comes from the wrong target (approval was retracted), it's discarded.
9. User responds from whichever side owns the approval → router constructs `ToolApproval(id, decision)` and puts it on `inbox` → `_run_agent` unblocks

### Retraction Protocol

```json
// Agent -> GUI (retract an approval the GUI is showing)
{"type": "tool_approval_retracted", "id": 12345678901234567890, "reason": "routed_to_telegram"}
```

GUI removes or greys out the approval prompt on receipt. If the GUI receives a `tool_approval` response for a retracted ID, it ignores it.

For Telegram retraction, the adapter calls `deleteMessage` using the stored `telegram_message_id`.

## Telegram Adapter

```julia
mutable struct TelegramAdapter <: ChannelAdapter
    bot_token::String
    chat_id::Int64                          # Forum-enabled group
    owner_id::Int64                         # Access control: only process messages from this user
    topic_map::Dict{String, Int64}          # project_id -> thread_id
    approvals_topic_id::Int64               # Dedicated approvals thread
    gateway::Union{PresenceRouter, Nothing} # Set at start!() time
    poll_task::Union{Task, Nothing}         # Async long polling task
    message_cache::Dict{String, DateTime}   # Dedup cache (5 min TTL)
    db::SQLite.DB
end
```

### Connection

- Long polling via Telegram Bot API `getUpdates` (HTTP.jl, 30s timeout)
- Reconnects automatically after Mac sleep (poll times out and retries)
- If 409 conflict, log warning and back off

### Access Control

Only process messages from `owner_id`. Everything else silently ignored.

### Forum Topic Mapping

- On startup, sync existing projects to Telegram forum topics
- On new project creation, create a new forum topic
- Mapping stored in `channel_topics` SQLite table
- Dedicated "Approvals" topic for tool approval requests

### Inbound Message Routing

When a regular message (not an approval callback) arrives in a project's forum topic:

1. Adapter resolves `topic_thread_id` → `project_id` via reverse lookup on `topic_map`
2. Calls `on_inbound(gateway, InboundEnvelope{:telegram}(...))`
3. The router creates a new `run_agent` task for the message, with the project's context — same as how `json_io.jl` handles a `user_message` from the GUI
4. Agent responses are sent back to the same Telegram forum topic via `OutboundEnvelope{:telegram}`
5. Each Telegram topic maps to one conversation at a time. If a conversation is already running for that project, the inbound message is queued until the current conversation completes (or a "cancel" command is sent)

### Message Formatting

- Agent responses formatted as Telegram MarkdownV2
- Long responses (>4096 chars) split at paragraph boundaries into multiple messages

### Callback Queries

Inline keyboard button presses arrive as callback queries. The adapter maps the callback data to the pending approval ID and calls `on_inbound` with the decision.

### Deduplication

Short-lived cache keyed by `(chat_id, message_id)` with 5 min TTL. Evicted lazily — stale entries are removed on each poll cycle before processing new updates.

## Integration Points

### main.jl

- `_run_agent` is unchanged — it still uses `outbox`/`inbox` channels with `ToolCallRequest`/`ToolApproval`
- The `PresenceRouter` becomes a field on shared state, but `_run_agent` doesn't interact with it directly

### json_io.jl

- The outbox consumer loop intercepts `ToolCallRequest` events and delegates to `route_approval` on the `PresenceRouter` instead of sending directly to the GUI
- Add `is_active` / `is_active_response` to the JSON protocol
- Add `tool_approval_retracted` outbound event type
- Existing `tool_approval` handler checks whether the approval is still owned by the GUI (not retracted) before forwarding
- On startup, if `config.yaml` has `gateway.telegram`, construct adapter, register with router, call `start!`

### New Files

```
gateway/
├── gateway.jl          # PresenceRouter, envelope types, adapter interface
├── telegram.jl         # TelegramAdapter implementation
└── telegram_api.jl     # Low-level Telegram Bot API wrapper
```

### SQLite Schema

```sql
CREATE TABLE IF NOT EXISTS channel_topics (
    project_id TEXT NOT NULL,
    channel TEXT NOT NULL,
    topic_thread_id INTEGER NOT NULL,
    chat_id INTEGER NOT NULL,
    PRIMARY KEY (project_id, channel)
);
```

### Config (config.yaml)

```yaml
gateway:
  idle_threshold_mins: 15   # When to fall back from GUI to Telegram
  telegram:
    bot_token: "123456:ABC-DEF..."
    chat_id: -1001234567890
    owner_id: 12345678
```

## Error Handling

- **Telegram API failures**: Retry with exponential backoff (1s, 2s, 4s, max 30s). Never silently drop approval delivery.
- **Invalid/revoked bot token**: Log error, disable adapter. Don't crash agent.
- **409 conflict**: Another polling instance exists. Log warning, back off.
- **Long responses**: Split at paragraph boundaries to stay under 4096 char Telegram limit.
- **Project created at runtime**: Adapter creates new forum topic, updates `channel_topics` table.
- **GUI process not running**: Router treats as inactive, routes to Telegram immediately.
- **No gateway configured**: If `gateway.telegram` is absent from `config.yaml`, no adapter is created. The `PresenceRouter` has an empty `active_adapters` list and all routing goes to the GUI — current behavior is fully preserved.
