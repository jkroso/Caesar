import { useState, useEffect } from "react";
import { ChevronRight, Wrench } from "lucide-react";
import type { ActivityStep } from "@/types/message";

interface Props {
  steps: ActivityStep[];
  collapsed: boolean;
  inputTokens?: number;
  outputTokens?: number;
}

function formatTokens(n: number): string {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + "M";
  if (n >= 1_000) return (n / 1_000).toFixed(1) + "k";
  return String(n);
}

export default function ActivityBlock({ steps, collapsed, inputTokens, outputTokens }: Props) {
  const [expanded, setExpanded] = useState(!collapsed);

  useEffect(() => {
    if (collapsed) setExpanded(false);
  }, [collapsed]);

  const toolCalls = steps.filter((s) => s.type === "tool_call");
  const uniqueTools = [...new Set(toolCalls.map((s) => s.name))];

  const parts: string[] = [];
  if (uniqueTools.length > 0) {
    parts.push(`Used ${uniqueTools.join(", ")} (${toolCalls.length} call${toolCalls.length !== 1 ? "s" : ""})`);
  }
  if (inputTokens || outputTokens) {
    const totalTokens = (inputTokens ?? 0) + (outputTokens ?? 0);
    parts.push(`${formatTokens(totalTokens)} tokens`);
  }
  const summary = parts.length > 0 ? parts.join(" \u00b7 ") : "Thinking...";

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
        <div className="ml-5 mt-1 border-l-2 border-[var(--color-border)] pl-3 flex flex-col gap-1.5">
          {steps.map((step, i) => (
            <div key={i} className="text-[11px]">
              {step.type === "tool_call" ? (
                <div>
                  <span className="font-mono text-[var(--color-accent)]">{step.name}()</span>
                  <pre className="mt-0.5 text-[var(--color-text-muted)] text-[10px] overflow-x-auto max-w-[500px] whitespace-pre-wrap break-all m-0">{step.detail.slice(0, 200)}</pre>
                </div>
              ) : (
                <div>
                  <span className="text-[var(--color-text-muted)]">{"\u2192"} </span>
                  <span className="text-[var(--color-text-muted)] text-[10px]">{step.detail.slice(0, 200)}</span>
                </div>
              )}
            </div>
          ))}
          {(inputTokens || outputTokens) && (
            <div className="text-[10px] text-[var(--color-text-muted)] pt-1 border-t border-[var(--color-border)]">
              {inputTokens ? `${formatTokens(inputTokens)} in` : ""}
              {inputTokens && outputTokens ? " \u00b7 " : ""}
              {outputTokens ? `${formatTokens(outputTokens)} out` : ""}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
