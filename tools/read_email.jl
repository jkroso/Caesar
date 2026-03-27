module read_email
const prosca = parentmodule(@__MODULE__)

const name = "read_email"
const description = "Read a specific email message"
const parameters = Dict(
  "type" => "object",
  "properties" => Dict(
    "folder_id" => Dict("type" => "string", "description" => "Folder ID"),
    "message_id" => Dict("type" => "string", "description" => "Message ID")),
  "required" => ["folder_id", "message_id"])
const needs_confirm = false

function fn(args)::String
  auth = prosca.MAIL_AUTH[]
  auth === nothing && return "Email not configured. Add gateway.zoho_mail section to config.yaml"
  try
    fid = string(args["folder_id"])
    mid = string(args["message_id"])
    result = prosca.mail_get(auth, fid, mid)
    try prosca.mail_mark_read(auth, mid, fid) catch end
    data = get(result, "data", result)
    from = get(data, "fromAddress", "unknown")
    to = get(data, "toAddress", "")
    subject = get(data, "subject", "(no subject)")
    date = get(data, "receivedTime", "")
    mid = string(get(data, "messageId", ""))
    content = get(data, "content", "")
    plain = replace(content, r"<[^>]+>" => "")
    plain = replace(plain, r"&nbsp;" => " ")
    plain = replace(plain, r"&amp;" => "&")
    plain = replace(plain, r"&lt;" => "<")
    plain = replace(plain, r"&gt;" => ">")
    plain = strip(replace(plain, r"\n{3,}" => "\n\n"))
    """From: $from
To: $to
Subject: $subject
Date: $date
Message-ID: $mid

$plain"""
  catch e
    "Failed to read email: $e"
  end
end

end
