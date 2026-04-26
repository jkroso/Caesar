import { Plus, Trash2 } from "lucide-react";
import { useCalcs } from "@/contexts/CalcsContext";

interface Props { onSelect: () => void }

export default function CalcsSidebarList({ onSelect }: Props) {
  const { state, createCalc, deleteCalc, setActive } = useCalcs();

  return (
    <div className="flex flex-col gap-1 px-2 py-1">
      <button
        onClick={async () => {
          const c = await createCalc("Untitled");
          setActive(c.id);
          onSelect();
        }}
        className="flex items-center gap-1 px-2 py-1 text-xs text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-muted)] rounded-md cursor-pointer appearance-none border-none bg-transparent"
      >
        <Plus size={12} /> New calc
      </button>
      {state.index.length === 0 && (
        <p className="px-2 py-1 text-xs text-[var(--color-text-muted)]">No calcs yet.</p>
      )}
      {state.index.map(entry => (
        <div key={entry.id}
             className={`group flex items-center justify-between px-2 py-1 rounded-md text-xs cursor-pointer ${
               state.activeId === entry.id
                 ? "bg-[var(--color-bg-muted)] text-[var(--color-text)]"
                 : "text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-muted)]"
             }`}
             onClick={() => { setActive(entry.id); onSelect(); }}>
          <span className="truncate">{entry.name}</span>
          <button
            onClick={(e) => { e.stopPropagation(); if (confirm(`Delete "${entry.name}"?`)) deleteCalc(entry.id); }}
            className="opacity-0 group-hover:opacity-100 appearance-none bg-transparent border-none cursor-pointer text-[var(--color-text-muted)] hover:text-red-500"
          >
            <Trash2 size={10} />
          </button>
        </div>
      ))}
    </div>
  );
}
