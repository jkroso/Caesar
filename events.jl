# Agent → Interface events
struct AgentMessage
  text::String
end

struct ToolCallRequest
  name::String
  args::String
  id::UInt64
end

struct ToolResult
  name::String
  result::String
end

struct AgentDone end

# Interface → Agent events
struct UserInput
  text::String
end

struct ToolApproval
  id::UInt64
  decision::Symbol  # :allow, :deny, :always
end

struct ToolApprovalRetracted
  id::UInt64
  reason::String  # e.g. "routed_to_telegram", "routed_to_gui"
end
