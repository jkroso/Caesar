import type { ChatMessage } from "./message";

type WithConversationId<T> = T & { conversation_id?: string };

export type SidecarEvent =
  | WithConversationId<{ type: "agent_message"; text: string }>
  | WithConversationId<{ type: "tool_call_request"; id: string; name: string; args: string }>
  | WithConversationId<{ type: "tool_result"; name: string; args?: string; result: string }>
  | WithConversationId<{ type: "agent_done"; input_tokens?: number; output_tokens?: number }>
  | WithConversationId<{ type: "error"; text: string }>
  | { type: "ready" }
  | WithConversationId<{ type: "command_result"; name: string; result: string }>
  | { type: "config"; data: Record<string, unknown> }
  | { type: "slash_completions"; data: SlashItem[] }
  | { type: "commands"; data: SlashItem[] }
  | { type: "personality"; file: string; content: string }
  | { type: "mcp_servers"; data: Record<string, McpServerInfo> }
  | { type: "skills"; data: SkillInfo[] }
  | { type: "models"; data: ModelInfo[] }
  | { type: "model_search_results"; data: ModelSearchResult[]; query: string }
  | { type: "providers"; data: ProviderInfo[] }
  | WithConversationId<{ type: "title"; title: string }>
  | { type: "projects"; data: ProjectInfo[] }
  | { type: "routines"; data: RoutineInfo[] }
  | { type: "routine_runs"; data: RoutineRunInfo[] }
  | { type: "notification"; text: string; project_id?: string; routine_id?: string }
  | { type: "unseen_count"; count: number }
  | { type: "agents"; data: AgentInfo[] }
  | { type: "conversations"; data: ConversationInfo[] };

export interface McpServerInfo {
  url: string;
  runtime: boolean;
  connected: boolean;
  tools: McpToolInfo[];
}

export interface McpToolInfo {
  name: string;
  description: string;
  schema: unknown;
}

export interface SkillInfo {
  name: string;
  description: string;
  file: string;
}

export interface ModelInfo {
  id: string;
  name: string;
  provider: string;
  family?: string;
  release_date?: string;
  modalities?: { input?: string[]; output?: string[] };
  reasoning?: boolean;
  tool_call?: boolean;
  cost?: {
    input?: number;
    output?: number;
    cache_read?: number;
    cache_write?: number;
    reasoning?: number;
    input_audio?: number;
    output_audio?: number;
    [key: string]: unknown;
  };
}

export interface ModelSearchResult {
  id: string;
  name: string;
  provider: string;
  reasoning: boolean;
  tool_call: boolean;
  context: number | null;
  cost: { input?: number; output?: number } | null;
  modalities?: { input?: string[]; output?: string[] };
}

export interface ProviderInfo {
  id: string;
  name: string;
  logo: string | null; // base64 data URI for SVG logo
}

export type SidecarStatus = "disconnected" | "starting" | "ready" | "error";

export interface ProjectInfo {
  id: string;
  name: string;
  path: string;
  is_default: boolean;
  paused: boolean;
  model: string | null;
  idle_check_mins: number;
  tokens_used: number;
  cost_usd: number;
  last_checked_at: string | null;
  created_at: string;
  routine_count: number;
}

export interface RoutineInfo {
  id: string;
  project_id: string;
  project_name: string;
  name: string;
  prompt: string;
  model: string | null;
  schedule_natural: string | null;
  schedule_cron: string | null;
  enabled: boolean;
  tokens_used: number;
  cost_usd: number;
  last_run_at: string | null;
  next_run_at: string | null;
  created_at: string;
}

export interface AgentInfo {
  id: string;
}

export interface ConversationInfo {
  id: string;
  agent_id: string;
  title: string;
  handed_off_to?: string | null;
  handed_off_from?: string | null;
  created_at: string;
  updated_at: string;
  messages?: ChatMessage[];
}

export interface SlashItem {
  name: string;
  description: string;
  kind: "command" | "skill";
}

export interface RoutineRunInfo {
  id: number;
  routine_id: string | null;
  project_id: string;
  started_at: string;
  finished_at: string;
  result: string;
  tokens_used: number;
  cost_usd: number;
  notable: boolean;
  seen: boolean;
}
