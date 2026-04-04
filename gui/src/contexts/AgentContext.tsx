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
  const { call } = useSidecar();
  const [agents, setAgents] = useState<AgentInfo[]>([]);

  const fetchAgents = useCallback(() => {
    call({ type: "agents_list" }).then((res) => setAgents(res.data));
  }, [call]);

  useEffect(() => { fetchAgents(); }, [fetchAgents]);

  const createAgent = useCallback((name: string, description: string) => {
    call({ type: "agent_create", name, description }).then((res) => setAgents(res.data));
  }, [call]);

  const deleteAgent = useCallback((id: string) => {
    call({ type: "agent_delete", id }).then((res) => setAgents(res.data));
  }, [call]);

  const updateAgent = useCallback((id: string, soul: string, instructions: string) => {
    call({ type: "agent_update", id, soul, instructions }).then((res) => setAgents(res.data));
  }, [call]);

  const refreshAgents = fetchAgents;

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
