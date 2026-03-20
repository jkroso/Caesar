import { useState } from "react";
import ModelSelector from "@/components/layout/ModelSelector";
import { useProjects } from "@/contexts/ProjectContext";

interface Props {
  onClose: () => void;
}

export default function ProjectForm({ onClose }: Props) {
  const { createProject } = useProjects();
  const [path, setPath] = useState("");
  const [name, setName] = useState("");
  const [nameManual, setNameManual] = useState(false);
  const [model, setModel] = useState("");
  const [idleMins, setIdleMins] = useState(30);

  const derivedName = path.trim().split("/").filter(Boolean).pop() || "";

  const handlePathChange = (val: string) => {
    setPath(val);
    if (!nameManual) setName("");
  };

  const handleNameChange = (val: string) => {
    setName(val);
    setNameManual(val !== "");
  };

  const displayName = nameManual ? name : derivedName;

  const handleSubmit = () => {
    if (!path.trim() || !displayName) return;
    createProject(displayName, path.trim(), model || undefined, idleMins);
    onClose();
  };

  const inputClass = "border border-[var(--color-border)] rounded-lg px-3 py-1.5 text-[13px] font-sans bg-[var(--color-bg-elevated)] text-[var(--color-text)] outline-none focus:border-[var(--color-accent)] w-full";

  return (
    <div className="border border-[var(--color-border)] rounded-xl bg-[var(--color-bg-elevated)] p-4 mb-3" style={{ animation: "fadeIn 200ms ease" }}>
      <h3 className="text-[14px] font-semibold mb-4">Add Project</h3>
      <div className="flex flex-col gap-3">
        <div>
          <label className="text-[11px] text-[var(--color-text-muted)] uppercase tracking-wider font-semibold mb-1 block">Folder Path</label>
          <input className={inputClass} value={path} onChange={(e) => handlePathChange(e.target.value)} placeholder="/Users/jake/projects/my-project" />
        </div>
        <div>
          <label className="text-[11px] text-[var(--color-text-muted)] uppercase tracking-wider font-semibold mb-1 block">Name</label>
          <input className={inputClass} value={displayName} onChange={(e) => handleNameChange(e.target.value)} placeholder={derivedName || "Project name"} />
          {!nameManual && derivedName && (
            <span className="text-[10px] text-[var(--color-text-muted)] mt-0.5 block">Auto-derived from path</span>
          )}
        </div>
        <div>
          <label className="text-[11px] text-[var(--color-text-muted)] uppercase tracking-wider font-semibold mb-1 block">Model (optional)</label>
          <ModelSelector value={model} onChange={setModel} />
        </div>
        <div>
          <label className="text-[11px] text-[var(--color-text-muted)] uppercase tracking-wider font-semibold mb-1 block">Idle Check Interval (minutes)</label>
          <input className={inputClass} type="number" min={5} value={idleMins} onChange={(e) => setIdleMins(parseInt(e.target.value) || 30)} />
        </div>
        <div className="flex gap-2 mt-2">
          <button onClick={handleSubmit} className="appearance-none border-none bg-[var(--color-accent)] text-white px-4 py-1.5 rounded-lg text-[12px] font-semibold cursor-pointer hover:bg-[var(--color-accent-hover)]">
            Add
          </button>
          <button onClick={onClose} className="appearance-none border-none bg-[var(--color-bg-muted)] text-[var(--color-text-secondary)] px-4 py-1.5 rounded-lg text-[12px] font-semibold cursor-pointer hover:opacity-80">
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
}
