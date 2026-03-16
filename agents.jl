# agents.jl — Multi-agent system: struct, loading, creation, migration

@use "github.com/jkroso/URI.jl/FSPath" FSPath

struct Agent
    id::String
    personality::String
    instructions::String
    skills::Dict{String, Skill}
    path::FSPath
end

const AGENTS = Dict{String, Agent}()

"""Load skills from an agent's skills/ directory."""
function load_agent_skills(agent_path::FSPath)::Dict{String, Skill}
    skills = Dict{String, Skill}()
    skills_dir = agent_path * "skills"
    isdir(skills_dir) || return skills
    for file in skills_dir.children
        file.extension == "md" || continue
        skill = parse_skill(string(file))
        skill === nothing && continue
        skills[skill.name] = skill
    end
    skills
end

const AGENTS_DIR = HOME*"agents"

"""Load a single agent from its directory."""
function load_agent(agent_dir::FSPath)::Union{Agent, Nothing}
    id = agent_dir.name
    soul_path = agent_dir*"soul.md"
    instr_path = agent_dir*"instructions.md"
    isfile(soul_path) && isfile(instr_path) || return nothing
    Agent(
        id,
        read(soul_path, String),
        read(instr_path, String),
        load_agent_skills(agent_dir),
        agent_dir
    )
end

"""Scan ~/Prosca/agents/ and load all agents."""
function load_agents!()
    empty!(AGENTS)
    isdir(AGENTS_DIR) || return
    for entry in AGENTS_DIR.children
        isdir(entry) || continue
        agent = load_agent(entry)
        agent === nothing && continue
        AGENTS[agent.id] = agent
        @info "Loaded agent: $(agent.id) ($(length(agent.skills)) local skills)"
    end
end

"""Migrate root soul.md/instructions.md to agents/prosca/ on first run."""
function migrate_to_agents!()
    isdir(AGENTS_DIR) && return  # already migrated

    root_soul = HOME * "soul.md"
    root_instr = HOME * "instructions.md"
    (isfile(root_soul) && isfile(root_instr)) || return

    prosca_dir = mkpath(AGENTS_DIR * "prosca")

    cp(root_soul, prosca_dir * "soul.md")
    cp(root_instr, prosca_dir * "instructions.md")

    # Copy skills if they exist
    root_skills = HOME * "skills"
    if isdir(root_skills)
        prosca_skills = mkpath(prosca_dir * "skills")
        for file in root_skills.children
            file.extension == "md" || continue
            cp(file, prosca_skills * file.name)
        end
    end

    @info "Migrated root soul.md/instructions.md to agents/prosca/"
end

"""Create a new agent with LLM-generated soul and instructions."""
function create_agent!(name::String, description::String)::Union{Agent, Nothing}
    agent_dir = AGENTS_DIR * name
    isdir(agent_dir) && return nothing  # already exists

    mkpath(agent_dir)
    mkpath(agent_dir * "skills")

    # Generate soul.md and instructions.md via LLM
    soul_content, instr_content = try
        gen_msgs = [
            PromptingTools.SystemMessage("""You are creating a new AI agent persona. Generate two markdown files based on the description.

Reply in this exact format:
===SOUL===
<soul.md content: personality, tone, values — 3-5 short paragraphs>
===INSTRUCTIONS===
<instructions.md content: capabilities, constraints, how to approach tasks — bullet points>"""),
            PromptingTools.UserMessage("Agent name: $name\nDescription: $description")
        ]
        result = call_llm(gen_msgs).content
        soul_match = match(r"===SOUL===\s*\n(.*?)===INSTRUCTIONS===\s*\n(.*)"s, result)
        if soul_match !== nothing
            strip(String(soul_match.captures[1])), strip(String(soul_match.captures[2]))
        else
            "# $name\n\n$description", "# Instructions\n\n- $description"
        end
    catch e
        @warn "LLM generation failed for agent $name, using template" exception=e
        "# $name\n\n$description", "# Instructions\n\n- $description"
    end

    write(agent_dir * "soul.md", soul_content)
    write(agent_dir * "instructions.md", instr_content)

    agent = load_agent(agent_dir)
    agent !== nothing && (AGENTS[name] = agent)
    agent
end

"""Delete an agent (prosca cannot be deleted)."""
function delete_agent!(id::String)::Bool
    id == "prosca" && return false
    haskey(AGENTS, id) || return false
    agent = AGENTS[id]
    delete!(AGENTS, id)
    rm(agent.path; recursive=true, force=true)
    true
end

"""Update an agent's soul.md and/or instructions.md, reload from disk."""
function update_agent!(id::String; soul::Union{String,Nothing}=nothing, instructions::Union{String,Nothing}=nothing)::Bool
    haskey(AGENTS, id) || return false
    agent = AGENTS[id]
    soul !== nothing && write(agent.path * "soul.md", soul)
    instructions !== nothing && write(agent.path * "instructions.md", instructions)
    # Reload
    updated = load_agent(agent.path)
    updated !== nothing && (AGENTS[id] = updated)
    true
end

"""Get the default agent."""
function default_agent()::Agent
    get(AGENTS, "prosca", first(values(AGENTS)))
end

"""Merge agent-local skills over global skills. Local wins on name collision."""
function merged_skills(agent::Agent)::Dict{String, Skill}
    merged = copy(SKILLS)
    merge!(merged, agent.skills)
    merged
end
