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
  const { call, status } = useSidecar();
  const [routines, setRoutines] = useState<RoutineInfo[]>([]);

  const fetchRoutines = useCallback((projectId?: string) => {
    call({ type: "routines_list", project_id: projectId }).then((res) => setRoutines(res.data));
  }, [call]);

  useEffect(() => {
    if (status === "ready") fetchRoutines();
  }, [status, fetchRoutines]);

  const createRoutine = useCallback((projectId: string, prompt: string, scheduleNatural: string, model?: string) => {
    call({ type: "routine_create", project_id: projectId, prompt, schedule_natural: scheduleNatural, model: model || undefined })
      .then((res) => setRoutines(res.data));
  }, [call]);

  const updateRoutine = useCallback((id: string, updates: Record<string, unknown>) => {
    call({ type: "routine_update", id, ...updates }).then((res) => setRoutines(res.data));
  }, [call]);

  const deleteRoutine = useCallback((id: string) => {
    call({ type: "routine_delete", id }).then((res) => setRoutines(res.data));
  }, [call]);

  return (
    <RoutineContext.Provider value={{ routines, fetchRoutines, createRoutine, updateRoutine, deleteRoutine }}>
      {children}
    </RoutineContext.Provider>
  );
}

export function useRoutines() { return useContext(RoutineContext); }
