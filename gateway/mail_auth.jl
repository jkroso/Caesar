# gateway/mail_auth.jl — OAuth 2.0 token management for Zoho Mail API

@use HTTP
@use JSON3
@use Dates...
@use Logging

mutable struct MailAuth
  client_id::String
  client_secret::String
  refresh_token::String
  account_id::String
  from_address::String
  base_url::String          # e.g. "https://mail.zoho.com" or "https://mail.zoho.eu"
  auth_url::String          # e.g. "https://accounts.zoho.com" or "https://accounts.zoho.eu"
  access_token::String
  expires_at::DateTime
end

function MailAuth(cfg::AbstractDict)
  region = get(cfg, "region", "com")
  MailAuth(
    cfg["client_id"],
    cfg["client_secret"],
    cfg["refresh_token"],
    cfg["account_id"],
    cfg["from_address"],
    "https://mail.zoho.$(region)",
    "https://accounts.zoho.$(region)",
    "",
    DateTime(0)
  )
end

"""
  ensure_token!(auth) -> String

Return a valid access token, refreshing via OAuth if expired.
"""
function ensure_token!(auth::MailAuth)::String
  if auth.access_token != "" && now() < auth.expires_at
    return auth.access_token
  end
  url = "$(auth.auth_url)/oauth/v2/token"
  resp = HTTP.post(url,
    ["Content-Type" => "application/x-www-form-urlencoded"],
    HTTP.URIs.escapeuri(Dict(
      "grant_type" => "refresh_token",
      "client_id" => auth.client_id,
      "client_secret" => auth.client_secret,
      "refresh_token" => auth.refresh_token
    ));
    status_exception=false)

  data = JSON3.read(String(resp.body))
  if haskey(data, :access_token)
    auth.access_token = data.access_token
    expires_in = get(data, :expires_in, 3600)
    auth.expires_at = now() + Second(expires_in - 60)  # 60s buffer
    @debug "Zoho Mail token refreshed, expires in $(expires_in)s"
    return auth.access_token
  else
    error("OAuth token refresh failed: $(String(resp.body))")
  end
end
