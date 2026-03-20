import { useState } from "react";
import { ChevronRight, Pause, Play, Trash2 } from "lucide-react";
import { useProjects } from "@/contexts/ProjectContext";
import ActivityFeed from "./ActivityFeed";
import type { ProjectInfo } from "@/types/sidecar";

interface Props {
  project: ProjectInfo;
}

export default function ProjectRow({ project }: Props) {
  const { runs, fetchRuns, markRunsSeen, updateProject, deleteProject } = useProjects();
  const [expanded, setExpanded] = useState(false);
  const [pausedLocal, setPausedLocal] = useState(project.paused ?? false);

  // Sync if backend sends an updated value
  if ((project.paused ?? false) !== pausedLocal && project.paused !== undefined) {
    setPausedLocal(project.paused);
  }

  const paused = pausedLocal;

  const handleExpand = () => {
    if (!expanded) {
      fetchRuns(project.id);
    }
    setExpanded(!expanded);
  };

  const handleTogglePause = (e: React.MouseEvent) => {
    e.stopPropagation();
    const next = !paused;
    setPausedLocal(next);
    updateProject(project.id, { paused: next });
  };

  const projectRuns = runs.filter((r) => r.project_id === project.id && r.notable);

  // Mark unseen runs as seen when expanded
  const unseenIds = projectRuns.filter((r) => !r.seen).map((r) => r.id);
  if (expanded && unseenIds.length > 0) {
    markRunsSeen(unseenIds);
  }

  const timeAgo = (iso: string | null) => {
    if (!iso) return "Never";
    const diff = Date.now() - new Date(iso + "Z").getTime();
    const mins = Math.floor(diff / 60000);
    if (mins < 1) return "Just now";
    if (mins < 60) return `${mins}m ago`;
    const hrs = Math.floor(mins / 60);
    if (hrs < 24) return `${hrs}h ago`;
    return `${Math.floor(hrs / 24)}d ago`;
  };

  return (
    <div className="border border-[var(--color-border)] rounded-xl bg-[var(--color-bg-elevated)] overflow-hidden"
         style={{ transition: "border-color 200ms ease" }}>
      <div className="flex items-center gap-3 px-4 py-3 cursor-pointer hover:bg-[var(--color-bg-muted)]"
           onClick={handleExpand}>
        <ChevronRight size={14} className={`text-[var(--color-text-muted)] transition-transform ${expanded ? "rotate-90" : ""}`} />
        <div
          className={`w-[7px] h-[7px] rounded-full ${paused ? "bg-[var(--color-text-muted)]" : "bg-[var(--color-success)]"}`}
          style={!paused ? { boxShadow: "0 0 6px rgba(22, 163, 74, 0.4)" } : undefined}
        />
        <span className={`text-[13px] font-medium flex-1 ${paused ? "text-[var(--color-text-muted)]" : ""}`}>{project.name}</span>
        {paused && (
          <span className="text-[9px] text-[var(--color-text-muted)] bg-[var(--color-bg-muted)] px-2 py-0.5 rounded-full font-semibold tracking-wider">
            PAUSED
          </span>
        )}
        <span className="text-[10px] text-[var(--color-text-muted)]">{project.routine_count} routines</span>
        <span className="text-[10px] text-[var(--color-text-muted)]">{timeAgo(project.last_checked_at)}</span>
        {project.tokens_used > 0 && (
          <span className="text-[10px] text-[var(--color-text-muted)]">
            {(project.tokens_used / 1000).toFixed(1)}k · ${project.cost_usd.toFixed(2)}
          </span>
        )}
        {project.is_default && (
          <span className="text-[9px] text-[var(--color-accent)] bg-[var(--color-accent-soft)] px-2 py-0.5 rounded-full font-semibold tracking-wider">
            DEFAULT
          </span>
        )}
      </div>
      {expanded && (
        <div className="px-4 pb-4 pt-1 border-t border-[var(--color-border)]" style={{ animation: "fadeIn 200ms ease" }}>
          <div className="flex flex-col gap-3">
            <div className="flex items-center justify-between">
              <div className="text-[11px] text-[var(--color-text-muted)] font-mono">{project.path}</div>
              <div className="flex items-center gap-2">
                <button
                  onClick={handleTogglePause}
                  className={`appearance-none border-none px-2.5 py-1 rounded-lg text-[11px] font-semibold cursor-pointer flex items-center gap-1.5 ${
                    paused
                      ? "bg-[var(--color-success)] text-white hover:opacity-90"
                      : "bg-[var(--color-bg-muted)] text-[var(--color-text-secondary)] hover:opacity-80"
                  }`}
                >
                  {paused ? <Play size={11} /> : <Pause size={11} />}
                  {paused ? "Resume" : "Pause"}
                </button>
                {!project.is_default && (
                  <button
                    onClick={(e) => { e.stopPropagation(); if (confirm(`Remove "${project.name}" from Prosca?`)) deleteProject(project.id); }}
                    className="appearance-none border-none px-2.5 py-1 rounded-lg text-[11px] font-semibold cursor-pointer flex items-center gap-1.5 text-[var(--color-error)] bg-[var(--color-bg-muted)] hover:opacity-80"
                  >
                    <Trash2 size={11} />
                    Delete
                  </button>
                )}
              </div>
            </div>
            {project.model && (
              <div className="text-[11px] text-[var(--color-text-secondary)]">
                Model: <span className="text-[var(--color-accent)]">{project.model}</span>
              </div>
            )}
            <div>
              <div className="text-[10px] text-[var(--color-text-muted)] font-semibold uppercase tracking-wider mb-2">
                Notable Activity
              </div>
              <ActivityFeed runs={projectRuns} />
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
