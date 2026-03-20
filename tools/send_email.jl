module send_email
const prosca = parentmodule(@__MODULE__)

const name = "send_email"
const schema = """{"tool": "send_email", "args": {"to": "recipient@example.com", "subject": "...", "body": "...", "cc": "(optional)", "bcc": "(optional)", "in_reply_to": "(optional message_id for threading)"}}"""
const needs_confirm = true

function fn(args)::String
  auth = prosca.MAIL_AUTH[]
  auth === nothing && return "Email not configured. Add gateway.zoho_mail section to config.yaml"
  to = args.to
  subject = args.subject
  body = args.body
  cc = get(args, :cc, "")
  bcc = get(args, :bcc, "")
  in_reply_to = get(args, :in_reply_to, "")
  try
    prosca.mail_send(auth; to, subject, content=body, cc, bcc, in_reply_to)
    "Email sent to $to — subject: \"$subject\""
  catch e
    "Failed to send email: $e"
  end
end

end
