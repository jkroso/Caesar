import type { ChatMessage } from "./message";

export interface Conversation {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  messages: ChatMessage[];
  busy?: boolean;
  agentId: string;
  handedOffTo?: string;
  handedOffFrom?: string;
}
