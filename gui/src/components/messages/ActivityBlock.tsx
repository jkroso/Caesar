import { useState } from "react";
import { ChevronRight, Wrench } from "lucide-react";
import type { ActivityStep } from "@/types/message";

interface Props {
  steps: ActivityStep[];
  collapsed: boolean;
}

export default function ActivityBlock({ steps, collapsed }: Props) {
  const [expanded, setExpanded] = useState(!collapsed);

  const toolCalls = steps.filter((s) => s.type === "tool_call");
  const uniqueTools = [...new Set(toolCalls.map((s) => s.name))];
  const summary = uniqueTools.length > 0
    ? `Used ${uniqueTools.join(", ")} (${toolCalls.length} call${toolCalls.length !== 1 ? "s" : ""})`
    : "Thinking...";

  return (
    <div className="mb-3" style={{ animation: "fadeIn 200ms ease forwards" }}>
      <button
        onClick={() => setExpanded(!expanded)}
        className="appearance-none border-none bg-transparent cursor-pointer flex items-center gap-1.5 text-[11px] text-[var(--color-text-muted)] hover:text-[var(--color-text-secondary)] py-1"
      >
        <ChevronRight
          size={12}
          className="transition-transform"
          style={{ transform: expanded ? "rotate(90deg)" : "rotate(0deg)" }}
        />
        <Wrench size={11} />
        <span>{summary}</span>
      </button>
      {expanded && (
        <div className="ml-5 mt-1 border-l-2 border-[var(--color-border)] pl-3 flex flex-col gap-1">
          {steps.map((step, i) => (
            <div key={i} className="text-[11px] flex items-start gap-2">
              <span className={`shrink-0 font-mono ${
                step.type === "tool_call"
                  ? "text-[var(--color-accent)]"
                  : "text-[var(--color-text-muted)]"
              }`}>
                {step.type === "tool_call" ? `${step.name}()` : `\u2192`}
              </span>
              <span className="text-[var(--color-text-muted)] overflow-hidden text-ellipsis whitespace-nowrap max-w-[500px]">
                {step.detail.slice(0, 120)}
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
