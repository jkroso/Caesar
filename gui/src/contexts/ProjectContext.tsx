import { createContext, useContext, useState, useEffect, useCallback, type ReactNode } from "react";
import { useSidecar } from "./SidecarContext";
import type { ProjectInfo, RoutineRunInfo } from "@/types/sidecar";

interface ProjectContextValue {
  projects: ProjectInfo[];
  runs: RoutineRunInfo[];
  unseenCount: number;
  fetchProjects: () => void;
  createProject: (name: string, path: string, model?: string, idleCheckMins?: number) => void;
  updateProject: (id: string, updates: Record<string, unknown>) => void;
  deleteProject: (id: string) => void;
  fetchRuns: (projectId?: string, unseenOnly?: boolean) => void;
  markRunsSeen: (ids: number[]) => void;
}

const ProjectContext = createContext<ProjectContextValue>(null!);

export function ProjectProvider({ children }: { children: ReactNode }) {
  const { send, onEvent, status } = useSidecar();
  const [projects, setProjects] = useState<ProjectInfo[]>([]);
  const [runs, setRuns] = useState<RoutineRunInfo[]>([]);
  const [unseenCount, setUnseenCount] = useState(0);

  useEffect(() => {
    const unsubscribe = onEvent((event) => {
      if (event.type === "projects") setProjects(event.data);
      if (event.type === "routine_runs") setRuns(event.data);
      if (event.type === "unseen_count") setUnseenCount(event.count);
    });
    return unsubscribe;
  }, [onEvent]);

  useEffect(() => {
    if (status === "ready") send({ type: "projects_list" });
  }, [status, send]);

  const fetchProjects = useCallback(() => send({ type: "projects_list" }), [send]);

  const createProject = useCallback((name: string, path: string, model?: string, idleCheckMins?: number) => {
    send({ type: "project_create", name, path, model: model || undefined, idle_check_mins: idleCheckMins ?? 30 });
  }, [send]);

  const updateProject = useCallback((id: string, updates: Record<string, unknown>) => {
    send({ type: "project_update", id, ...updates });
  }, [send]);

  const deleteProject = useCallback((id: string) => {
    send({ type: "project_delete", id });
  }, [send]);

  const fetchRuns = useCallback((projectId?: string, unseenOnly?: boolean) => {
    send({ type: "routine_runs_list", project_id: projectId, unseen_only: unseenOnly });
  }, [send]);

  const markRunsSeen = useCallback((ids: number[]) => {
    send({ type: "routine_runs_mark_seen", ids });
  }, [send]);

  return (
    <ProjectContext.Provider value={{ projects, runs, unseenCount, fetchProjects, createProject, updateProject, deleteProject, fetchRuns, markRunsSeen }}>
      {children}
    </ProjectContext.Provider>
  );
}

export function useProjects() { return useContext(ProjectContext); }
