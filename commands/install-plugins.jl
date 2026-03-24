module install_plugins
const prosca = parentmodule(@__MODULE__)

const name = "install-plugins"
const description = "Clone a plugin repo and symlink its skills and tools"

function fn(args::String)::String
  url = strip(args)
  isempty(url) && return "Usage: /install-plugins <git-url>"

  # Parse repo name from URL
  m = match(r"([^/]+?)(?:\.git)?$", url)
  m === nothing && return "Could not parse repo name from URL"
  repo_name = m.captures[1]

  plugins_dir = prosca.HOME * "plugins"
  plugins_dir.exists || mkpath(plugins_dir)
  clone_path = plugins_dir * repo_name

  # Clone or pull
  if clone_path.exists
    @info "Updating existing plugin: $repo_name"
    run(Cmd(`git -C $(string(clone_path)) pull`))
  else
    @info "Cloning plugin: $repo_name"
    run(Cmd(`git clone $url $(string(clone_path))`))
  end

  installed_skills = String[]
  installed_tools = String[]

  # Symlink skills
  skills_src = clone_path * "skills"
  if skills_src.exists
    for file in skills_src.children
      file.extension == "md" || continue
      target = prosca.SKILLS_DIR * file.name
      target.exists && rm(string(target))
      symlink(string(file), string(target))
      push!(installed_skills, file.name)
    end
  end

  # Symlink tools
  tools_dir = prosca.HOME * "tools"
  tools_src = clone_path * "tools"
  if tools_src.exists
    for file in tools_src.children
      file.extension == "jl" || continue
      target = tools_dir * file.name
      target.exists && rm(string(target))
      symlink(string(file), string(target))
      push!(installed_tools, file.name)
    end
  end

  # Reload
  prosca.load_skills!()
  prosca.load_tools!()
  prosca.load_commands!()

  parts = String[]
  !isempty(installed_skills) && push!(parts, "Skills: $(join(installed_skills, ", "))")
  !isempty(installed_tools) && push!(parts, "Tools: $(join(installed_tools, ", "))")
  isempty(parts) && return "Plugin '$repo_name' cloned but no skills or tools found."
  "✅ Installed from $repo_name:\n" * join(parts, "\n")
end

end
