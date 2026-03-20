import { Plus } from "lucide-react";
import { open } from "@tauri-apps/plugin-dialog";
import { useProjects } from "@/contexts/ProjectContext";
import ProjectRow from "@/components/projects/ProjectRow";

export default function ProjectsPage() {
  const { projects, createProject } = useProjects();

  const handleAdd = async () => {
    const selected = await open({ directory: true, multiple: false, title: "Select project folder" });
    if (!selected) return;
    const path = typeof selected === "string" ? selected : selected[0];
    if (!path) return;
    const name = path.split("/").filter(Boolean).pop() || "Untitled";
    createProject(name, path);
  };

  return (
    <div className="flex-1 overflow-y-auto p-6 max-w-[900px]" style={{ animation: "fadeIn 300ms ease" }}>
      <div className="flex items-center justify-between mb-6">
        <div>
          <h2 className="text-[18px] font-semibold tracking-[-0.02em] mb-1">Projects</h2>
          <p className="text-[13px] text-[var(--color-text-muted)]">Folders the agent monitors and works on</p>
        </div>
        <button onClick={handleAdd} className="appearance-none border-none bg-[var(--color-accent)] text-white px-3 py-1.5 rounded-lg text-[12px] font-semibold cursor-pointer flex items-center gap-1.5 hover:bg-[var(--color-accent-hover)]">
          <Plus size={14} /> Add Project
        </button>
      </div>
      <div className="flex flex-col gap-3">
        {projects.map((p) => (
          <ProjectRow key={p.id} project={p} />
        ))}
        {projects.length === 0 && (
          <p className="text-[var(--color-text-muted)] text-[13px]">No projects yet</p>
        )}
      </div>
    </div>
  );
}
