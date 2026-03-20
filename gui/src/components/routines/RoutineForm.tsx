import { useState } from "react";
import ModelSelector from "@/components/layout/ModelSelector";
import { useRoutines } from "@/contexts/RoutineContext";
import { useProjects } from "@/contexts/ProjectContext";

interface Props {
  onClose: () => void;
  defaultProjectId?: string;
}

export default function RoutineForm({ onClose, defaultProjectId }: Props) {
  const { createRoutine } = useRoutines();
  const { projects } = useProjects();
  const [projectId, setProjectId] = useState(defaultProjectId || projects.find((p) => p.is_default)?.id || "");
  const [prompt, setPrompt] = useState("");
  const [schedule, setSchedule] = useState("");
  const [model, setModel] = useState("");

  const handleSubmit = () => {
    if (!prompt.trim() || !projectId) return;
    createRoutine(projectId, prompt.trim(), schedule.trim(), model || undefined);
    onClose();
  };

  const inputClass = "border border-[var(--color-border)] rounded-lg px-3 py-1.5 text-[13px] font-sans bg-[var(--color-bg-elevated)] text-[var(--color-text)] outline-none focus:border-[var(--color-accent)] w-full";

  return (
    <div className="border border-[var(--color-border)] rounded-xl bg-[var(--color-bg-elevated)] p-4" style={{ animation: "fadeIn 200ms ease" }}>
      <h3 className="text-[14px] font-semibold mb-4">New Routine</h3>
      <div className="flex flex-col gap-3">
        <div>
          <label className="text-[11px] text-[var(--color-text-muted)] uppercase tracking-wider font-semibold mb-1 block">Project</label>
          <select className={inputClass} value={projectId} onChange={(e) => setProjectId(e.target.value)}>
            {projects.map((p) => (
              <option key={p.id} value={p.id}>{p.name}{p.is_default ? " (Default)" : ""}</option>
            ))}
          </select>
        </div>
        <div>
          <label className="text-[11px] text-[var(--color-text-muted)] uppercase tracking-wider font-semibold mb-1 block">Prompt</label>
          <textarea className={inputClass + " min-h-[80px] resize-y"} value={prompt} onChange={(e) => setPrompt(e.target.value)}
                    placeholder="Check the weather forecast for Denver, CO and summarize any notable conditions" />
        </div>
        <div>
          <label className="text-[11px] text-[var(--color-text-muted)] uppercase tracking-wider font-semibold mb-1 block">Schedule</label>
          <input className={inputClass} value={schedule} onChange={(e) => setSchedule(e.target.value)} placeholder="Every morning at 8am" />
        </div>
        <div>
          <label className="text-[11px] text-[var(--color-text-muted)] uppercase tracking-wider font-semibold mb-1 block">Model (optional)</label>
          <ModelSelector value={model} onChange={setModel} />
        </div>
        <div className="flex gap-2 mt-2">
          <button onClick={handleSubmit} className="appearance-none border-none bg-[var(--color-accent)] text-white px-4 py-1.5 rounded-lg text-[12px] font-semibold cursor-pointer hover:bg-[var(--color-accent-hover)]">
            Create
          </button>
          <button onClick={onClose} className="appearance-none border-none bg-[var(--color-bg-muted)] text-[var(--color-text-secondary)] px-4 py-1.5 rounded-lg text-[12px] font-semibold cursor-pointer hover:opacity-80">
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
}
