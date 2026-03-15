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
Unicode-safe: uses ncodeunits and prevind for safe byte boundary indexing.
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
