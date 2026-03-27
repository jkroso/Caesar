module check_email
const prosca = parentmodule(@__MODULE__)

const name = "check_email"
const description = "List recent emails in the inbox"
const parameters = Dict(
  "type" => "object",
  "properties" => Dict(
    "limit" => Dict("type" => "integer", "description" => "Max emails to return", "default" => 10)),
  "required" => [])
const needs_confirm = false

function fn(args)::String
  auth = prosca.MAIL_AUTH[]
  auth === nothing && return "Email not configured. Add gateway.zoho_mail section to config.yaml"
  limit = get(args, "limit", 10)
  try
    result = prosca.mail_list(auth; limit)
    data = get(result, "data", result)
    isempty(data) && return "Inbox is empty"
    lines = String[]
    for (i, msg) in enumerate(data)
      from = get(msg, "fromAddress", "unknown")
      subject = get(msg, "subject", "(no subject)")
      date = get(msg, "receivedTime", "")
      mid = string(get(msg, "messageId", ""))
      fid = string(get(msg, "folderId", ""))
      push!(lines, "$i. From: $from | Subject: $subject | Date: $date | ID: $mid | Folder: $fid")
    end
    join(lines, "\n")
  catch e
    "Failed to check email: $e"
  end
end

end
