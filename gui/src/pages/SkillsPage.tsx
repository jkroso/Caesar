import { useEffect, useState } from "react";
import { useSidecar } from "@/contexts/SidecarContext";
import SkillCard from "@/components/skills/SkillCard";
import type { SkillInfo } from "@/types/sidecar";

export default function SkillsPage() {
  const { call } = useSidecar();
  const [skills, setSkills] = useState<SkillInfo[]>([]);

  useEffect(() => {
    call({ type: "skills_list" }).then((res) => setSkills(res.data));
  }, [call]);

  return (
    <div className="flex-1 overflow-y-auto p-6 max-w-[900px]" style={{ animation: "fadeIn 300ms ease" }}>
      <h2 className="text-[18px] font-semibold tracking-[-0.02em] mb-1">Skills</h2>
      <p className="text-[13px] text-[var(--color-text-muted)] mb-6">Loaded from the skills/ directory</p>
      <div className="grid grid-cols-[repeat(auto-fill,minmax(280px,1fr))] gap-4">
        {skills.map((s) => (
          <SkillCard key={s.name} skill={s} />
        ))}
        {skills.length === 0 && (
          <p className="text-[var(--color-text-muted)] text-[13px]">No skills found</p>
        )}
      </div>
    </div>
  );
}
