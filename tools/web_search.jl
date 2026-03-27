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
  @use "github.com/jkroso/HTTP.jl/client" GET
  @use "github.com/jkroso/JSON.jl" parse_json
  @use "github.com/jkroso/HTTP.jl" escapeuri
  try
    url = "https://api.duckduckgo.com/?q=$(escapeuri(args["query"]))&format=json&no_html=1&skip_disambig=1"
    resp = GET(url)
    data = parse_json(read(resp, String))
    abstract_text = get(data, "Abstract", "")
    topics = join([get(t, "Text", "") for t in get(data, "RelatedTopics", [])], "\n")
    result = "$abstract_text\n\nRelated: $topics"
    result[1:min(2000, end)]
  catch
    "Web search failed (offline?)"
  end
end

end
