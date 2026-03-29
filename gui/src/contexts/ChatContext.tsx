import { createContext, useContext, useReducer, useCallback, useEffect, useRef, type ReactNode } from "react";
import { useSidecar } from "./SidecarContext";
import { useConversations } from "./ConversationContext";
import type { ChatMessage, ActivityStep } from "@/types/message";
import type { SidecarEvent } from "@/types/sidecar";

interface ChatState {
  messages: ChatMessage[];
  pendingCount: number;
}

type ChatAction =
  | { type: "add_message"; message: ChatMessage }
  | { type: "insert_before_queued"; message: ChatMessage }
  | { type: "update_tool_decision"; id: string; decision: "allow" | "deny" | "always" }
  | { type: "append_activity_step"; step: ActivityStep }
  | { type: "collapse_activity" }
  | { type: "increment_pending" }
  | { type: "decrement_pending" }
  | { type: "dequeue_next" }
  | { type: "clear" }
  | { type: "restore"; messages: ChatMessage[]; pendingCount?: number };

function chatReducer(state: ChatState, action: ChatAction): ChatState {
  switch (action.type) {
    case "add_message":
      return { ...state, messages: [...state.messages, action.message] };
    case "insert_before_queued": {
      // Insert agent/tool responses before any queued user messages
      const idx = state.messages.findIndex((m) => m.role === "user" && "queued" in m && m.queued);
      if (idx === -1) {
        return { ...state, messages: [...state.messages, action.message] };
      }
      const newMessages = [...state.messages];
      newMessages.splice(idx, 0, action.message);
      return { ...state, messages: newMessages };
    }
    case "update_tool_decision":
      return {
        ...state,
        messages: state.messages.map((m) =>
          m.role === "tool_request" && m.id === action.id
            ? { ...m, decision: action.decision }
            : m
        ),
      };
    case "append_activity_step": {
      const msgs = [...state.messages];
      const lastIdx = msgs.length - 1;
      const last = lastIdx >= 0 ? msgs[lastIdx] : null;
      if (last && last.role === "activity" && !last.collapsed) {
        msgs[lastIdx] = { ...last, steps: [...last.steps, action.step] };
      } else {
        msgs.push({ role: "activity", steps: [action.step], collapsed: false, timestamp: action.step.timestamp });
      }
      return { ...state, messages: msgs };
    }
    case "collapse_activity": {
      return {
        ...state,
        messages: state.messages.map((m) =>
          m.role === "activity" && !m.collapsed ? { ...m, collapsed: true } : m
        ),
      };
    }
    case "increment_pending":
      return { ...state, pendingCount: state.pendingCount + 1 };
    case "decrement_pending":
      return { ...state, pendingCount: Math.max(0, state.pendingCount - 1) };
    case "dequeue_next": {
      const idx = state.messages.findIndex((m) => m.role === "user" && "queued" in m && m.queued);
      if (idx === -1) return state;
      const newMessages = [...state.messages];
      const msg = newMessages[idx];
      if (msg.role === "user") {
        newMessages[idx] = { ...msg, queued: undefined };
      }
      return { ...state, messages: newMessages };
    }
    case "clear":
      return { messages: [], pendingCount: 0 };
    case "restore":
      return { messages: action.messages, pendingCount: action.pendingCount ?? 0 };
    default:
      return state;
  }
}

interface ChatContextValue {
  messages: ChatMessage[];
  agentBusy: boolean;
  sendMessage: (text: string, attachments?: import("@/types/message").Attachment[]) => void;
  approveToolCall: (id: string, decision: "allow" | "deny" | "always") => void;
  clearChat: () => void;
}

const ChatContext = createContext<ChatContextValue | null>(null);

export function ChatProvider({ children }: { children: ReactNode }) {
  const { send, onEvent } = useSidecar();
  const { activeId, conversations, saveMessages, appendMessage, getMessages, renameConversation, createConversation, setBusy, isBusy } = useConversations();
  const [state, dispatch] = useReducer(chatReducer, { messages: [], pendingCount: 0 });
  const prevActiveId = useRef(activeId);
  const stateRef = useRef(state);
  stateRef.current = state;
  const activeIdRef = useRef(activeId);
  activeIdRef.current = activeId;
  const conversationsRef = useRef(conversations);
  conversationsRef.current = conversations;
  const titleRequestedRef = useRef<Set<string>>(new Set());

  // Save/restore messages when switching conversations
  useEffect(() => {
    if (prevActiveId.current !== activeId) {
      const wasNull = prevActiveId.current === null;

      // Save current messages to the conversation we're leaving
      if (prevActiveId.current) {
        saveMessages(prevActiveId.current, stateRef.current.messages);
      }
      prevActiveId.current = activeId;

      // If transitioning from no conversation (null) to a new one,
      // keep current messages and send any queued ones
      if (wasNull && activeId) {
        const queued = stateRef.current.messages.find(
          (m): m is Extract<ChatMessage, { role: "user" }> => m.role === "user" && !!m.queued
        );
        if (queued) {
          dispatch({ type: "dequeue_next" });
          const conv = conversationsRef.current.find((c) => c.id === activeId);
          const agentId = conv?.agentId ?? "prosca";
          const payload: Record<string, unknown> = { type: "user_message", text: queued.text, conversation_id: activeId, agent_id: agentId };
          if (queued.attachments?.length) {
            payload.attachments = queued.attachments.map(a => ({ mime: a.mime, data: a.data }));
          }
          send(payload);
          setBusy(activeId, true);
        }
        return;
      }

      // Restore messages and busy state from the conversation we're switching to
      if (activeId) {
        const saved = getMessages(activeId);
        const busy = isBusy(activeId);
        if (saved.length > 0) {
          dispatch({ type: "restore", messages: saved, pendingCount: busy ? 1 : 0 });
          // Restore backend context from user/agent message pairs
          const contextMessages = saved
            .filter((m): m is Extract<ChatMessage, { role: "user" | "agent" }> => m.role === "user" || m.role === "agent")
            .map((m) => ({ role: m.role, text: m.text }));
          send({ type: "restore_context", messages: contextMessages });
        } else {
          dispatch({ type: "clear" });
          send({ type: "reset" });
        }
      } else {
        dispatch({ type: "clear" });
        send({ type: "reset" });
      }
    }
  }, [activeId, send, saveMessages, getMessages]);

  // Persist messages to the active conversation as they change
  useEffect(() => {
    if (activeId && state.messages.length > 0) {
      saveMessages(activeId, state.messages);
    }
  }, [activeId, state.messages, saveMessages]);

  useEffect(() => {
    const unsubscribe = onEvent((event: SidecarEvent) => {
      const now = Date.now();
      // Determine which conversation this event belongs to
      const eventConvId = "conversation_id" in event ? event.conversation_id : undefined;
      const isForActive = !eventConvId || eventConvId === activeIdRef.current;

      switch (event.type) {
        case "agent_message": {
          let text = event.text;
          // Extract final_answer — may be pure JSON or embedded at end of text
          try {
            const parsed = JSON.parse(text);
            if (typeof parsed === "object" && parsed !== null && typeof parsed.final_answer === "string") {
              text = parsed.final_answer;
            }
          } catch {
            // Try to extract {"final_answer": "..."} from end of text
            const match = text.match(/\{"final_answer":\s*"(.*)"\}\s*$/s);
            if (match) {
              text = match[1].replace(/\\n/g, "\n").replace(/\\"/g, '"').replace(/\\\\/g, "\\");
            }
          }
          console.log("%c[Agent] Message", "color: #8b5cf6; font-weight: bold", text);
          const agentMsg = { role: "agent" as const, text, timestamp: now };
          if (isForActive) {
            dispatch({ type: "insert_before_queued", message: agentMsg });
          } else {
            appendMessage(eventConvId!, agentMsg);
          }
          break;
        }
        case "tool_call_request": {
          console.log("%c[Agent] Tool Call → %s", "color: #f59e0b; font-weight: bold", event.name, event.args);
          // Still show approval card for tool requests that need confirmation
          const toolReqMsg = { role: "tool_request" as const, id: event.id, name: event.name, args: event.args, timestamp: now };
          if (isForActive) {
            dispatch({ type: "insert_before_queued", message: toolReqMsg });
            dispatch({ type: "append_activity_step", step: { type: "tool_call", name: event.name, detail: event.args, timestamp: now } });
          } else {
            appendMessage(eventConvId!, toolReqMsg);
          }
          break;
        }
        case "tool_result": {
          console.log("%c[Agent] Tool Result ← %s", "color: #10b981; font-weight: bold", event.name, event.result);
          if (isForActive) {
            dispatch({ type: "append_activity_step", step: { type: "tool_result", name: event.name, detail: event.result, timestamp: now } });
          }
          break;
        }
        case "command_result": {
          if (isForActive) {
            dispatch({ type: "add_message", message: { role: "agent", text: event.result, timestamp: now } });
            dispatch({ type: "decrement_pending" });
          }
          if (eventConvId) setBusy(eventConvId, false);
          break;
        }
        case "agent_done": {
          console.log("%c[Agent] Done", "color: #6b7280; font-weight: bold");
          if (isForActive) {
            dispatch({ type: "collapse_activity" });
            dispatch({ type: "decrement_pending" });
            const convId = eventConvId || activeIdRef.current;
            // Generate title after first response completes (deferred to avoid racing the LLM)
            if (convId && !titleRequestedRef.current.has(convId)) {
              titleRequestedRef.current.add(convId);
              const firstUserMsg = stateRef.current.messages.find((m) => m.role === "user");
              if (firstUserMsg && firstUserMsg.role === "user") {
                send({ type: "generate_title", text: firstUserMsg.text, conversation_id: convId });
              }
            }
            // Send next queued message if any
            const nextQueued = stateRef.current.messages.find(
              (m): m is Extract<ChatMessage, { role: "user" }> => m.role === "user" && !!m.queued
            );
            if (nextQueued) {
              dispatch({ type: "dequeue_next" });
              dispatch({ type: "increment_pending" });
              if (convId) {
                const conv = conversationsRef.current.find((c) => c.id === convId);
                const agentId = conv?.agentId ?? "prosca";
                const dqPayload: Record<string, unknown> = { type: "user_message", text: nextQueued.text, conversation_id: convId, agent_id: agentId };
                if (nextQueued.attachments?.length) {
                  dqPayload.attachments = nextQueued.attachments.map(a => ({ mime: a.mime, data: a.data }));
                }
                send(dqPayload);
              }
            } else if (eventConvId) {
              setBusy(eventConvId, false);
            }
          } else if (eventConvId) {
            setBusy(eventConvId, false);
          }
          break;
        }
        case "title": {
          console.log("%c[Agent] Title", "color: #3b82f6; font-weight: bold", event.title);
          const titleConvId = eventConvId || activeIdRef.current;
          if (titleConvId) {
            renameConversation(titleConvId, event.title);
          }
          break;
        }
        case "error": {
          console.error("%c[Agent] Error", "color: #ef4444; font-weight: bold", event.text);
          const errorMsg = { role: "error" as const, text: event.text, timestamp: now };
          if (isForActive) {
            dispatch({ type: "insert_before_queued", message: errorMsg });
          } else if (eventConvId) {
            appendMessage(eventConvId, errorMsg);
          }
          break;
        }
      }
    });
    return unsubscribe;
  }, [onEvent]);

  const sendMessage = useCallback(
    (text: string, attachments?: import("@/types/message").Attachment[]) => {
      const atts = attachments?.length ? attachments : undefined;
      // Auto-create a conversation if none is active
      if (!activeId) {
        createConversation();
        dispatch({ type: "add_message", message: { role: "user", text, timestamp: Date.now(), queued: true, attachments: atts } });
        dispatch({ type: "increment_pending" });
        return;
      }
      const convId = activeId;
      const activeConversation = conversations.find((c) => c.id === convId);
      const agentId = activeConversation?.agentId ?? "prosca";
      const busy = stateRef.current.pendingCount > 0;
      if (busy) {
        dispatch({ type: "add_message", message: { role: "user", text, timestamp: Date.now(), queued: true, attachments: atts } });
      } else {
        dispatch({ type: "add_message", message: { role: "user", text, timestamp: Date.now(), attachments: atts } });
        dispatch({ type: "increment_pending" });
        setBusy(convId, true);
        const payload: Record<string, unknown> = { type: "user_message", text, conversation_id: convId, agent_id: agentId };
        if (atts) {
          payload.attachments = atts.map(a => ({ mime: a.mime, data: a.data }));
        }
        send(payload);
      }
    },
    [send, activeId, conversations, createConversation, setBusy]
  );

  const approveToolCall = useCallback(
    (id: string, decision: "allow" | "deny" | "always") => {
      dispatch({ type: "update_tool_decision", id, decision });
      send({ type: "tool_approval", id, decision, conversation_id: activeIdRef.current });
    },
    [send]
  );

  const clearChat = useCallback(() => {
    dispatch({ type: "clear" });
    send({ type: "reset" });
  }, [send]);

  const agentBusy = state.pendingCount > 0;

  return (
    <ChatContext.Provider value={{ messages: state.messages, agentBusy, sendMessage, approveToolCall, clearChat }}>
      {children}
    </ChatContext.Provider>
  );
}

export function useChat() {
  const ctx = useContext(ChatContext);
  if (!ctx) throw new Error("useChat must be used within ChatProvider");
  return ctx;
}
