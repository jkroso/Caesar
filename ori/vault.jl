@use "./types" Note
@use Dates: DateTime, now, UTC
@use UUIDs: uuid4

const WIKILINK_RE = r"\[\[([^\]]+)\]\]"
const FRONTMATTER_RE = r"^---\s*\n(.*?)\n---\s*\n"s

extract_links(text) = [m.captures[1] for m in eachmatch(WIKILINK_RE, text)]

function parse_frontmatter(content::AbstractString)
  m = match(FRONTMATTER_RE, content)
  m === nothing && return (Dict{String,Any}(), content)
  meta = Dict{String,Any}()
  for line in split(m.captures[1], '\n')
    s = strip(line)
    isempty(s) && continue
    i = findfirst(':', s)
    i === nothing && continue
    meta[String(strip(s[1:i-1]))] = String(strip(s[i+1:end]))
  end
  (meta, String(content[length(m.match)+1:end]))
end

function read_note(path::AbstractString)
  content = read(path, String)
  meta, body = parse_frontmatter(content)
  title = get(meta, "title", splitext(basename(path))[1])
  tags_str = get(meta, "tags", "")
  tags = filter(!isempty, String.(strip.(split(tags_str, ","))))
  Note(id = get(meta, "id", string(uuid4())),
       title = title,
       description = get(meta, "description", ""),
       body = body,
       type = Symbol(get(meta, "type", "note")),
       tags = tags,
       links = extract_links(body),
       space = Symbol(get(meta, "space", "notes")),
       path = String(path),
       created = now(UTC),
       modified = now(UTC))
end

function load_vault(dir::AbstractString)
  notes = Note[]
  for (root, _, files) in walkdir(dir)
    for f in files
      endswith(f, ".md") || continue
      push!(notes, read_note(joinpath(root, f)))
    end
  end
  notes
end

function write_note(dir::AbstractString, note::Note)
  filename = replace(lowercase(note.title), r"[^a-z0-9]+" => "-") * ".md"
  space_dir = joinpath(dir, String(note.space))
  mkpath(space_dir)
  path = joinpath(space_dir, filename)
  open(path, "w") do io
    println(io, "---")
    println(io, "id: ", note.id)
    println(io, "title: ", note.title)
    isempty(note.description) || println(io, "description: ", note.description)
    println(io, "type: ", note.type)
    isempty(note.tags) || println(io, "tags: ", join(note.tags, ", "))
    println(io, "space: ", note.space)
    println(io, "---")
    println(io)
    print(io, note.body)
  end
  Note(id=note.id, title=note.title, description=note.description,
       body=note.body, type=note.type, tags=note.tags, links=note.links,
       space=note.space, path=path, created=note.created, modified=note.modified)
end
