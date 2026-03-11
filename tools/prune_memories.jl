module prune_memories
const prosca = parentmodule(@__MODULE__)

const name = "prune_memories"
const schema = """{"tool": "prune_memories", "args": {}}"""
const needs_confirm = false

fn(_) = prosca.prune_memories()

end
