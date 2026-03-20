import { useChat } from "@/contexts/ChatContext";

interface Props {
  id: string;
  name: string;
  args: string;
  decision?: "allow" | "deny" | "always";
}

export default function ToolApprovalCard({ id, name, args, decision }: Props) {
  const { approveToolCall } = useChat();

  let parsedArgs = args;
  try {
    parsedArgs = JSON.stringify(JSON.parse(args), null, 2);
  } catch {
    // args might not be valid JSON
  }

  if (decision) {
    const color = decision === "deny" ? "var(--color-error)" : "var(--color-success)";
    return (
      <div
        className="rounded-xl px-3.5 py-2.5 my-2 border"
        style={{ borderColor: `color-mix(in srgb, ${color} 30%, transparent)`, background: `color-mix(in srgb, ${color} 5%, transparent)` }}
      >
        <div className="flex items-center justify-between gap-2">
          <code className="text-[12px] font-mono font-medium">{name}</code>
          <span className="text-[11px] font-semibold capitalize tracking-wide" style={{ color }}>{decision}</span>
        </div>
      </div>
    );
  }

  return (
    <div className="rounded-xl p-3.5 my-2 bg-[var(--color-accent-soft)] border border-[color-mix(in_srgb,var(--color-accent)_25%,transparent)]">
      <div className="flex items-center justify-between gap-2">
        <span className="text-[11px] font-semibold text-[var(--color-accent)] uppercase tracking-wider">Tool Approval</span>
      </div>
      <div className="mt-2.5">
        <code className="text-[12px] font-mono font-medium">{name}</code>
        <pre className="font-mono text-[11px] bg-[var(--color-bg-muted)] p-2.5 rounded-lg mt-2 max-h-[120px] overflow-y-auto border border-[var(--color-border-subtle)]">{parsedArgs}</pre>
      </div>
      <div className="flex gap-2 mt-3">
        <button
          className="border-none px-3.5 py-1.5 rounded-lg text-[12px] cursor-pointer font-semibold text-white bg-[var(--color-success)] hover:opacity-90"
          onClick={() => approveToolCall(id, "allow")}
        >
          Allow
        </button>
        <button
          className="border-none px-3.5 py-1.5 rounded-lg text-[12px] cursor-pointer font-semibold text-white bg-[var(--color-error)] hover:opacity-90"
          onClick={() => approveToolCall(id, "deny")}
        >
          Deny
        </button>
        <button
          className="border-none px-3.5 py-1.5 rounded-lg text-[12px] cursor-pointer font-semibold text-[var(--color-accent)] bg-[var(--color-accent-soft)] hover:opacity-80"
          onClick={() => approveToolCall(id, "always")}
        >
          Always
        </button>
      </div>
    </div>
  );
}
