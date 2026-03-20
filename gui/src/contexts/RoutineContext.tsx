import { createContext, useContext, useState, useEffect, useCallback, type ReactNode } from "react";
import { useSidecar } from "./SidecarContext";
import type { RoutineInfo } from "@/types/sidecar";

interface RoutineContextValue {
  routines: RoutineInfo[];
  fetchRoutines: (projectId?: string) => void;
  createRoutine: (projectId: string, prompt: string, scheduleNatural: string, model?: string) => void;
  updateRoutine: (id: string, updates: Record<string, unknown>) => void;
  deleteRoutine: (id: string) => void;
}

const RoutineContext = createContext<RoutineContextValue>(null!);

export function RoutineProvider({ children }: { children: ReactNode }) {
  const { send, onEvent, status } = useSidecar();
  const [routines, setRoutines] = useState<RoutineInfo[]>([]);

  useEffect(() => {
    const unsubscribe = onEvent((event) => {
      if (event.type === "routines") setRoutines(event.data);
    });
    return unsubscribe;
  }, [onEvent]);

  useEffect(() => {
    if (status === "ready") send({ type: "routines_list" });
  }, [status, send]);

  const fetchRoutines = useCallback((projectId?: string) => {
    send({ type: "routines_list", project_id: projectId });
  }, [send]);

  const createRoutine = useCallback((projectId: string, prompt: string, scheduleNatural: string, model?: string) => {
    send({ type: "routine_create", project_id: projectId, prompt, schedule_natural: scheduleNatural, model: model || undefined });
  }, [send]);

  const updateRoutine = useCallback((id: string, updates: Record<string, unknown>) => {
    send({ type: "routine_update", id, ...updates });
  }, [send]);

  const deleteRoutine = useCallback((id: string) => {
    send({ type: "routine_delete", id });
  }, [send]);

  return (
    <RoutineContext.Provider value={{ routines, fetchRoutines, createRoutine, updateRoutine, deleteRoutine }}>
      {children}
    </RoutineContext.Provider>
  );
}

export function useRoutines() { return useContext(RoutineContext); }
