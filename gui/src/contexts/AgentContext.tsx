import { createContext, useContext, useState, useEffect, useCallback, type ReactNode } from "react";
import { useSidecar } from "./SidecarContext";
import type { AgentInfo } from "@/types/sidecar";

interface AgentContextValue {
  agents: AgentInfo[];
  createAgent: (name: string, description: string) => void;
  deleteAgent: (id: string) => void;
  updateAgent: (id: string, soul: string, instructions: string) => void;
  refreshAgents: () => void;
}

const AgentContext = createContext<AgentContextValue | null>(null);

export function AgentProvider({ children }: { children: ReactNode }) {
  const { send, onEvent } = useSidecar();
  const [agents, setAgents] = useState<AgentInfo[]>([]);

  useEffect(() => {
    return onEvent((event) => {
      if (event.type === "agents") {
        setAgents(event.data);
      }
    });
  }, [onEvent]);

  useEffect(() => {
    send({ type: "agents_list" });
  }, [send]);

  const createAgent = useCallback((name: string, description: string) => {
    send({ type: "agent_create", name, description });
  }, [send]);

  const deleteAgent = useCallback((id: string) => {
    send({ type: "agent_delete", id });
  }, [send]);

  const updateAgent = useCallback((id: string, soul: string, instructions: string) => {
    send({ type: "agent_update", id, soul, instructions });
  }, [send]);

  const refreshAgents = useCallback(() => {
    send({ type: "agents_list" });
  }, [send]);

  return (
    <AgentContext.Provider value={{ agents, createAgent, deleteAgent, updateAgent, refreshAgents }}>
      {children}
    </AgentContext.Provider>
  );
}

export function useAgents() {
  const ctx = useContext(AgentContext);
  if (!ctx) throw new Error("useAgents must be used within AgentProvider");
  return ctx;
}
