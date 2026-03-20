import { useState } from "react";
import type { SkillInfo } from "@/types/sidecar";

interface Props {
  skill: SkillInfo;
}

export default function SkillCard({ skill }: Props) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div
      className="border border-[var(--color-border)] rounded-xl p-4 bg-[var(--color-bg-elevated)] cursor-pointer hover:border-[var(--color-accent)] group"
      style={{ transition: "border-color 200ms ease, box-shadow 200ms ease" }}
      onClick={() => setExpanded(!expanded)}
    >
      <div className="flex items-center justify-between mb-2">
        <h3 className="text-[13px] font-semibold tracking-[-0.01em] group-hover:text-[var(--color-accent)]">{skill.name}</h3>
        <span className="text-[10px] text-[var(--color-text-muted)] font-mono bg-[var(--color-bg-muted)] px-1.5 py-0.5 rounded">{skill.file}</span>
      </div>
      <p className="text-[12px] text-[var(--color-text-secondary)] leading-relaxed">{skill.description || "No description"}</p>
    </div>
  );
}
