import { useState } from "react";
import { Plus } from "lucide-react";
import { useRoutines } from "@/contexts/RoutineContext";
import { useProjects } from "@/contexts/ProjectContext";
import RoutineForm from "@/components/routines/RoutineForm";

export default function RoutinesPage() {
  const [showForm, setShowForm] = useState(false);
  const { routines } = useRoutines();
  const { projects } = useProjects();

  // Group routines by project
  const grouped = projects.map((p) => ({
    project: p,
    routines: routines.filter((r) => r.project_id === p.id),
  })).filter((g) => g.routines.length > 0 || g.project.is_default);

  const timeAgo = (iso: string | null) => {
    if (!iso) return "";
    const diff = Date.now() - new Date(iso + "Z").getTime();
    const mins = Math.floor(diff / 60000);
    if (mins < 1) return "Just now";
    if (mins < 60) return `${mins}m ago`;
    const hrs = Math.floor(mins / 60);
    if (hrs < 24) return `${hrs}h ago`;
    return `${Math.floor(hrs / 24)}d ago`;
  };

  return (
    <div className="flex-1 overflow-y-auto p-6 max-w-[900px]" style={{ animation: "fadeIn 300ms ease" }}>
      <div className="flex items-center justify-between mb-6">
        <div>
          <h2 className="text-[18px] font-semibold tracking-[-0.02em] mb-1">Routines</h2>
          <p className="text-[13px] text-[var(--color-text-muted)]">Scheduled tasks grouped by project</p>
        </div>
        <button onClick={() => setShowForm(true)} className="appearance-none border-none bg-[var(--color-accent)] text-white px-3 py-1.5 rounded-lg text-[12px] font-semibold cursor-pointer flex items-center gap-1.5 hover:bg-[var(--color-accent-hover)]">
          <Plus size={14} /> New Routine
        </button>
      </div>
      {showForm && <RoutineForm onClose={() => setShowForm(false)} />}
      <div className="flex flex-col gap-5">
        {grouped.map(({ project, routines: projectRoutines }) => (
          <div key={project.id}>
            <div className="flex items-center gap-2 mb-2">
              <div className={`w-[7px] h-[7px] rounded-full ${project.is_default ? "bg-[var(--color-accent)]" : "bg-[var(--color-success)]"}`} />
              <span className="text-[10px] font-semibold text-[var(--color-text-muted)] uppercase tracking-wider">
                {project.name}
              </span>
            </div>
            <div className="flex flex-col gap-1.5 pl-4">
              {projectRoutines.map((r) => (
                <div
                  key={r.id}
                  className={`border border-[var(--color-border)] rounded-lg px-3 py-2.5 bg-[var(--color-bg-elevated)] flex items-center gap-3 ${
                    !r.enabled ? "opacity-50" : ""
                  }`}
                >
                  <div className={`w-[6px] h-[6px] rounded-full ${r.enabled ? "bg-[var(--color-success)]" : "bg-[var(--color-text-muted)]"}`} />
                  <span className={`text-[12px] flex-1 ${!r.enabled ? "line-through text-[var(--color-text-muted)]" : ""}`}>
                    {r.name}
                  </span>
                  {r.schedule_natural && (
                    <span className="text-[10px] text-[var(--color-text-muted)]">{r.schedule_natural}</span>
                  )}
                  {r.last_run_at && (
                    <span className="text-[10px] text-[var(--color-success)]">Ran {timeAgo(r.last_run_at)}</span>
                  )}
                  {r.tokens_used > 0 && (
                    <span className="text-[10px] text-[var(--color-text-muted)]">
                      {(r.tokens_used / 1000).toFixed(1)}k · ${r.cost_usd.toFixed(2)}
                    </span>
                  )}
                </div>
              ))}
              {projectRoutines.length === 0 && (
                <p className="text-[11px] text-[var(--color-text-muted)] pl-1">No routines yet</p>
              )}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
