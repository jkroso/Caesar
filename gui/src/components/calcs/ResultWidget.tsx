import { useState } from "react";
import { ChevronDown, Code as CodeIcon, Loader2 } from "lucide-react";
import type { CalcParagraph } from "@/types/sidecar";

interface Props {
  paragraph: CalcParagraph;
  renderedCode: string;
  translating: boolean;
}

export default function ResultWidget({ paragraph, renderedCode, translating }: Props) {
  const [expanded, setExpanded] = useState(false);
  const [showCode, setShowCode] = useState(false);

  if (translating) {
    return (
      <span className="inline-flex items-center gap-1 px-2 py-0.5 ml-2 rounded-md bg-[var(--color-bg-muted)] text-xs text-[var(--color-text-muted)]">
        <Loader2 size={11} className="animate-spin" />
        translating
      </span>
    );
  }

  if (paragraph.last_error) {
    return (
      <span className="inline-flex items-center gap-1 px-2 py-0.5 ml-2 rounded-md bg-red-50 text-xs text-red-700 cursor-pointer"
            title={paragraph.last_error}
            onClick={() => setExpanded(!expanded)}>
        error
      </span>
    );
  }

  const short = paragraph.last_value_short;
  if (short == null) return null;

  const canExpand = paragraph.last_value_long != null;

  return (
    <span className="inline-block ml-2 align-baseline">
      <span
        className="inline-flex items-center gap-1 px-2 py-0.5 rounded-md bg-[var(--color-bg-muted)] text-xs text-[var(--color-text-secondary)] cursor-pointer hover:bg-[var(--color-bg-elevated)]"
        onClick={() => canExpand && setExpanded(!expanded)}
      >
        <span className="font-mono">{short}</span>
        {canExpand && <ChevronDown size={10} className={expanded ? "rotate-180" : ""} />}
        <button
          onClick={(e) => { e.stopPropagation(); setShowCode(!showCode); }}
          className="appearance-none bg-transparent border-none cursor-pointer p-0 ml-1 text-[var(--color-text-muted)] hover:text-[var(--color-text)]"
          title="Show generated code"
        >
          <CodeIcon size={10} />
        </button>
      </span>
      {expanded && paragraph.last_value_long && (
        <pre className="mt-1 p-2 rounded-md bg-[var(--color-bg-muted)] text-xs font-mono whitespace-pre-wrap overflow-auto max-h-64">
          {paragraph.last_value_long}
        </pre>
      )}
      {showCode && (
        <pre className="mt-1 p-2 rounded-md bg-[var(--color-bg-elevated)] border border-[var(--color-border)] text-xs font-mono whitespace-pre-wrap">
          {renderedCode || "(no code)"}
        </pre>
      )}
    </span>
  );
}
