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
  const { call, onEvent, status } = useSidecar();
  const [projects, setProjects] = useState<ProjectInfo[]>([]);
  const [runs, setRuns] = useState<RoutineRunInfo[]>([]);
  const [unseenCount, setUnseenCount] = useState(0);

  // unseen_count is pushed by the backend (not a response to a request)
  useEffect(() => {
    return onEvent((event) => {
      if (event.type === "unseen_count") setUnseenCount(event.count);
    });
  }, [onEvent]);

  const fetchProjects = useCallback(() => {
    call({ type: "projects_list" }).then((res) => setProjects(res.data));
  }, [call]);

  useEffect(() => {
    if (status === "ready") fetchProjects();
  }, [status, fetchProjects]);

  const createProject = useCallback((name: string, path: string, model?: string, idleCheckMins?: number) => {
    call({ type: "project_create", name, path, model: model || undefined, idle_check_mins: idleCheckMins ?? 30 })
      .then((res) => setProjects(res.data));
  }, [call]);

  const updateProject = useCallback((id: string, updates: Record<string, unknown>) => {
    call({ type: "project_update", id, ...updates }).then((res) => setProjects(res.data));
  }, [call]);

  const deleteProject = useCallback((id: string) => {
    call({ type: "project_delete", id }).then((res) => setProjects(res.data));
  }, [call]);

  const fetchRuns = useCallback((projectId?: string, unseenOnly?: boolean) => {
    call({ type: "routine_runs_list", project_id: projectId, unseen_only: unseenOnly })
      .then((res) => setRuns(res.data));
  }, [call]);

  const markRunsSeen = useCallback((ids: number[]) => {
    call({ type: "routine_runs_mark_seen", ids }).then((res) => setUnseenCount(res.count));
  }, [call]);

  return (
    <ProjectContext.Provider value={{ projects, runs, unseenCount, fetchProjects, createProject, updateProject, deleteProject, fetchRuns, markRunsSeen }}>
      {children}
    </ProjectContext.Provider>
  );
}

export function useProjects() { return useContext(ProjectContext); }
