export interface Attachment {
  mime: string;
  data: string; // base64
  name: string;
}

export interface ActivityStep {
  type: "tool_call" | "tool_result";
  name: string;
  detail: string; // args for calls, result snippet for results
  timestamp: number;
}

export type ChatMessage =
  | { role: "user"; text: string; timestamp: number; queued?: boolean; attachments?: Attachment[] }
  | { role: "agent"; text: string; timestamp: number }
  | { role: "tool_request"; id: string; name: string; args: string; decision?: "allow" | "deny" | "always"; timestamp: number }
  | { role: "tool_result"; name: string; result: string; timestamp: number }
  | { role: "error"; text: string; timestamp: number }
  | { role: "activity"; steps: ActivityStep[]; collapsed: boolean; timestamp: number };
