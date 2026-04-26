import { useEffect } from "react";
import { useCalcs } from "@/contexts/CalcsContext";
import CalcEditor from "@/components/calcs/CalcEditor";

export default function CalcsPage() {
  const { state, loadCalc } = useCalcs();
  const activeCalc = state.activeId ? state.calcs[state.activeId] : null;

  useEffect(() => {
    if (state.activeId && !state.calcs[state.activeId]) {
      loadCalc(state.activeId);
    }
  }, [state.activeId, state.calcs, loadCalc]);

  if (!state.activeId) {
    return (
      <div className="flex flex-col items-center justify-center h-full text-[var(--color-text-secondary)] gap-2">
        <p>Select a calc from the sidebar, or create a new one.</p>
      </div>
    );
  }
  if (!activeCalc) {
    return <div className="flex items-center justify-center h-full text-[var(--color-text-muted)]">Loading…</div>;
  }
  return <CalcEditor calc={activeCalc} />;
}
