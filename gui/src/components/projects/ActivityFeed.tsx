import type { RoutineRunInfo } from "@/types/sidecar";

interface Props {
  runs: RoutineRunInfo[];
}

export default function ActivityFeed({ runs }: Props) {
  if (runs.length === 0) {
    return <p className="text-[12px] text-[var(--color-text-muted)]">No notable activity yet</p>;
  }
  return (
    <div className="flex flex-col gap-1.5">
      {runs.map((run) => (
        <div key={run.id} className="border-l-2 border-[var(--color-accent)] pl-3 py-1.5">
          <div className="flex items-center gap-2 mb-1">
            <span className="text-[10px] text-[var(--color-text-muted)]">
              {run.started_at ? new Date(run.started_at + "Z").toLocaleString() : ""}
            </span>
            <span className="text-[10px] text-[var(--color-text-muted)]">
              {run.tokens_used > 0 && `${(run.tokens_used / 1000).toFixed(1)}k tokens`}
              {run.cost_usd > 0 && ` · $${run.cost_usd.toFixed(2)}`}
            </span>
          </div>
          <p className="text-[12px] text-[var(--color-text-secondary)] leading-relaxed">{run.result}</p>
        </div>
      ))}
    </div>
  );
}
