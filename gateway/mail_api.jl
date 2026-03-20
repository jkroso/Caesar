# gateway/mail_api.jl — Low-level Zoho Mail REST API wrapper

@use "./mail_auth" MailAuth ensure_token!
@use HTTP
@use JSON3
@use Logging

struct MailAPIError <: Exception
  status::Int
  body::String
end

Base.showerror(io::IO, e::MailAPIError) = print(io, "Mail API error $(e.status): $(e.body)")

"""
  mail_request(auth, method, path; params, body) -> JSON3.Object

Make an authenticated request to the Zoho Mail API.
"""
function mail_request(auth::MailAuth, method::String, path::String;
                      params::Dict{String,Any}=Dict{String,Any}(),
                      body::Union{String,Nothing}=nothing)
  token = ensure_token!(auth)
  url = "$(auth.base_url)/api/accounts/$(auth.account_id)$(path)"
  if !isempty(params)
    url *= "?" * HTTP.URIs.escapeuri(params)
  end
  headers = ["Authorization" => "Zoho-oauthtoken $token", "Content-Type" => "application/json"]
  resp = if method == "GET"
    HTTP.get(url, headers; status_exception=false, connect_timeout=10, readtimeout=30)
  elseif method == "PUT"
    HTTP.put(url, headers, something(body, ""); status_exception=false, connect_timeout=10, readtimeout=30)
  else
    HTTP.post(url, headers, something(body, ""); status_exception=false, connect_timeout=10, readtimeout=30)
  end
  if resp.status >= 400
    throw(MailAPIError(resp.status, String(resp.body)))
  end
  JSON3.read(String(resp.body))
end

# ── Specific API methods ────────────────────────────────────────────

"""
  mail_send(auth; to, subject, body, cc, bcc, in_reply_to) -> Dict

Send an email. Returns the API response.
"""
function mail_send(auth::MailAuth; to::String, subject::String, content::String,
                   cc::String="", bcc::String="", in_reply_to::String="")
  payload = Dict{String,Any}(
    "fromAddress" => auth.from_address,
    "toAddress" => to,
    "subject" => subject,
    "content" => content
  )
  !isempty(cc) && (payload["ccAddress"] = cc)
  !isempty(bcc) && (payload["bccAddress"] = bcc)
  !isempty(in_reply_to) && (payload["inReplyTo"] = in_reply_to)
  mail_request(auth, "POST", "/messages", body=JSON3.write(payload))
end

"""
  mail_list(auth; folder_id, limit) -> Vector

List emails in a folder. Default: inbox, 10 messages.
"""
function mail_list(auth::MailAuth; folder_id::String="", limit::Int=10)
  # If no folder_id, we need to get the inbox folder ID first
  fid = folder_id
  if isempty(fid)
    folders = mail_request(auth, "GET", "/folders")
    data = get(folders, :data, folders)
    for f in data
      if lowercase(get(f, :folderName, "")) == "inbox"
        fid = string(get(f, :folderId, ""))
        break
      end
    end
    isempty(fid) && error("Could not find inbox folder")
  end
  params = Dict{String,Any}("folderId" => fid, "limit" => string(limit))
  mail_request(auth, "GET", "/messages/view", params=params)
end

"""
  mail_get(auth, message_id) -> Dict

Get full content of a specific email.
"""
function mail_get(auth::MailAuth, folder_id::String, message_id::String)
  mail_request(auth, "GET", "/folders/$(folder_id)/messages/$(message_id)/content")
end

"""
  mail_mark_read(auth, message_id, folder_id) -> Dict

Mark an email as read.
"""
function mail_mark_read(auth::MailAuth, message_id::String, folder_id::String)
  payload = Dict{String,Any}(
    "mode" => "markAsRead",
    "messageId" => [message_id],
    "folderId" => folder_id
  )
  mail_request(auth, "PUT", "/updatemessage", body=JSON3.write(payload))
end
