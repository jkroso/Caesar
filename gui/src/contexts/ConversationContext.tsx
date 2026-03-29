import { createContext, useContext, useState, useCallback, useEffect, useRef, type ReactNode } from "react";
import { useSidecar } from "./SidecarContext";
import type { Conversation } from "@/types/conversation";
import type { ChatMessage } from "@/types/message";
import type { ConversationInfo } from "@/types/sidecar";

interface ConversationContextValue {
  conversations: Conversation[];
  activeId: string | null;
  setActiveId: (id: string | null) => void;
  createConversation: (agentId?: string) => void;
  deleteConversation: (id: string) => void;
  renameConversation: (id: string, title: string) => void;
  saveMessages: (id: string, messages: ChatMessage[]) => void;
  appendMessage: (id: string, message: ChatMessage) => void;
  getMessages: (id: string) => ChatMessage[];
  setBusy: (id: string, busy: boolean) => void;
  isBusy: (id: string) => boolean;
}

const ConversationContext = createContext<ConversationContextValue | null>(null);

function infoToConversation(info: ConversationInfo, existing?: Conversation): Conversation {
  return {
    id: info.id,
    title: info.title,
    createdAt: new Date(info.created_at).getTime(),
    updatedAt: new Date(info.updated_at).getTime(),
    messages: existing?.messages?.length ? existing.messages : info.messages ?? [],
    busy: existing?.busy,
    agentId: info.agent_id,
    handedOffTo: info.handed_off_to ?? undefined,
    handedOffFrom: info.handed_off_from ?? undefined,
  };
}

export function ConversationProvider({ children }: { children: ReactNode }) {
  const { send, onEvent } = useSidecar();
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);
  // Track pending agent for auto-select after conversation_create
  const pendingAgentRef = useRef<string | null>(null);
  // Keep a ref to conversations for use in callbacks without stale closures
  const conversationsRef = useRef<Conversation[]>(conversations);
  conversationsRef.current = conversations;

  useEffect(() => {
    return onEvent((event) => {
      if (event.type === "conversations") {
        const infos: ConversationInfo[] = event.data;
        setConversations((prev) => {
          const prevMap = new Map(prev.map((c) => [c.id, c]));
          return infos.map((info) => infoToConversation(info, prevMap.get(info.id)));
        });

        // Auto-select the newest conversation for the pending agent
        if (pendingAgentRef.current !== null) {
          const agentId = pendingAgentRef.current;
          pendingAgentRef.current = null;
          // Find the most recently created conversation for this agent
          const forAgent = infos.filter((i) => i.agent_id === agentId);
          if (forAgent.length > 0) {
            const newest = forAgent.reduce((a, b) =>
              new Date(a.created_at).getTime() > new Date(b.created_at).getTime() ? a : b
            );
            setActiveId(newest.id);
          }
        }
      }
    });
  }, [onEvent]);

  // Request conversation list on mount
  useEffect(() => {
    send({ type: "conversations_list" });
  }, [send]);

  const createConversation = useCallback((agentId: string = "prosca") => {
    send({ type: "conversation_create", agent_id: agentId });
    pendingAgentRef.current = agentId;
  }, [send]);

  const deleteConversation = useCallback((id: string) => {
    send({ type: "conversation_delete", id });
    setConversations((prev) => prev.filter((c) => c.id !== id));
    setActiveId((current) => (current === id ? null : current));
  }, [send]);

  const renameConversation = useCallback((id: string, title: string) => {
    send({ type: "conversation_update_title", id, title });
    setConversations((prev) =>
      prev.map((c) => (c.id === id ? { ...c, title, updatedAt: Date.now() } : c))
    );
  }, [send]);

  const sendRef = useRef(send);
  sendRef.current = send;

  const saveMessages = useCallback((id: string, messages: ChatMessage[]) => {
    setConversations((prev) =>
      prev.map((c) => (c.id === id ? { ...c, messages, updatedAt: Date.now() } : c))
    );
    // Persist to backend DB
    if (messages.length > 0) {
      sendRef.current({ type: "conversation_save_messages", id, messages });
    }
  }, []);

  const appendMessage = useCallback((id: string, message: ChatMessage) => {
    setConversations((prev) =>
      prev.map((c) => (c.id === id ? { ...c, messages: [...c.messages, message], updatedAt: Date.now() } : c))
    );
  }, []);

  const getMessages = useCallback((id: string): ChatMessage[] => {
    return conversationsRef.current.find((c) => c.id === id)?.messages ?? [];
  }, []);

  const setBusy = useCallback((id: string, busy: boolean) => {
    setConversations((prev) =>
      prev.map((c) => (c.id === id ? { ...c, busy } : c))
    );
  }, []);

  const isBusy = useCallback((id: string): boolean => {
    return conversationsRef.current.find((c) => c.id === id)?.busy ?? false;
  }, []);

  return (
    <ConversationContext.Provider
      value={{ conversations, activeId, setActiveId, createConversation, deleteConversation, renameConversation, saveMessages, appendMessage, getMessages, setBusy, isBusy }}
    >
      {children}
    </ConversationContext.Provider>
  );
}

export function useConversations() {
  const ctx = useContext(ConversationContext);
  if (!ctx) throw new Error("useConversations must be used within ConversationProvider");
  return ctx;
}
