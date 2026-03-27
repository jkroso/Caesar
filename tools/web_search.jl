module web_search
const prosca = parentmodule(@__MODULE__)

const name = "web_search"
const description = "Search the web using DuckDuckGo"
const parameters = Dict(
  "type" => "object",
  "properties" => Dict("query" => Dict("type" => "string", "description" => "Search query")),
  "required" => ["query"])
const needs_confirm = false

function fn(args)::String
  try
    query = prosca.HTTP.escapeuri(args["query"])
    url = "https://api.duckduckgo.com/?q=$query&format=json&no_html=1&skip_disambig=1"
    resp = prosca.HTTP.GET(url)
    data = prosca.parse_json(read(resp, String))
    abstract_text = get(data, "Abstract", "")
    topics = join([get(t, "Text", "") for t in get(data, "RelatedTopics", [])], "\n")
    result = "$abstract_text\n\nRelated: $topics"
    result[1:min(2000, end)]
  catch
    "Web search failed (offline?)"
  end
end

end
