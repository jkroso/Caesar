module web_search
const prosca = parentmodule(@__MODULE__)

const name = "web_search"
const schema = """{"tool": "web_search", "args": {"query": "..."}}"""
const needs_confirm = false

function fn(args)::String
  try
    url = "https://api.duckduckgo.com/?q=$(prosca.HTTP.URIs.escapeuri(args.query))&format=json&no_html=1&skip_disambig=1"
    resp = prosca.HTTP.get(url, retry=true, connect_timeout=5, readtimeout=10)
    data = prosca.JSON3.read(resp.body)
    abstract_text = get(data, :Abstract, "")
    topics = join([get(t, :Text, "") for t in get(data, :RelatedTopics, [])], "\n")
    result = "$abstract_text\n\nRelated: $topics"
    result[1:min(2000, end)]
  catch
    "Web search failed (offline?)"
  end
end

end
