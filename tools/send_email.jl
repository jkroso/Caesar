module send_email
const prosca = parentmodule(@__MODULE__)

const name = "send_email"
const description = "Send an email via Zoho Mail"
const parameters = Dict(
  "type" => "object",
  "properties" => Dict(
    "to" => Dict("type" => "string", "description" => "Recipient email address"),
    "subject" => Dict("type" => "string", "description" => "Email subject"),
    "body" => Dict("type" => "string", "description" => "Email body"),
    "cc" => Dict("type" => "string", "description" => "CC recipients"),
    "bcc" => Dict("type" => "string", "description" => "BCC recipients"),
    "in_reply_to" => Dict("type" => "string", "description" => "Message-ID to reply to")),
  "required" => ["to", "subject", "body"])
const needs_confirm = true

function fn(args)::String
  auth = prosca.MAIL_AUTH[]
  auth === nothing && return "Email not configured. Add gateway.zoho_mail section to config.yaml"
  to = args["to"]
  subject = args["subject"]
  body = args["body"]
  cc = get(args, "cc", "")
  bcc = get(args, "bcc", "")
  in_reply_to = get(args, "in_reply_to", "")
  try
    prosca.mail_send(auth; to, subject, content=body, cc, bcc, in_reply_to)
    "Email sent to $to — subject: \"$subject\""
  catch e
    "Failed to send email: $e"
  end
end

end
