import { useState } from "react";
import { useAgents } from "@/contexts/AgentContext";

export default function AgentsPage() {
  const { agents, createAgent, deleteAgent } = useAgents();
  const [newName, setNewName] = useState("");
  const [newDescription, setNewDescription] = useState("");
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);

  const inputClass =
    "border border-[var(--color-border)] rounded-lg px-3 py-1.5 text-[13px] bg-[var(--color-bg-elevated)] text-[var(--color-text)] outline-none focus:border-[var(--color-accent)] w-full";

  const handleCreate = () => {
    const name = newName.trim();
    const description = newDescription.trim();
    if (!name) return;
    createAgent(name, description);
    setNewName("");
    setNewDescription("");
  };

  const handleDelete = (id: string) => {
    if (confirmDelete === id) {
      deleteAgent(id);
      setConfirmDelete(null);
    } else {
      setConfirmDelete(id);
    }
  };

  return (
    <div className="flex-1 overflow-y-auto p-6 max-w-[900px]" style={{ animation: "fadeIn 300ms ease" }}>
      <h2 className="text-[18px] font-semibold tracking-[-0.02em] mb-6">Agents</h2>

      {/* Create agent */}
      <section className="mb-8">
        <h3 className="text-[13px] font-semibold mb-4 pb-2.5 border-b border-[var(--color-border-subtle)] text-[var(--color-text-secondary)] uppercase tracking-wider">
          Create Agent
        </h3>
        <div className="flex flex-col gap-3 max-w-[480px]">
          <div className="flex flex-col gap-1">
            <label className="text-[12px] text-[var(--color-text-secondary)]">Name</label>
            <input
              className={inputClass}
              type="text"
              placeholder="my-agent"
              value={newName}
              onChange={(e) => setNewName(e.target.value)}
              onKeyDown={(e) => { if (e.key === "Enter") handleCreate(); }}
            />
          </div>
          <div className="flex flex-col gap-1">
            <label className="text-[12px] text-[var(--color-text-secondary)]">Description</label>
            <input
              className={inputClass}
              type="text"
              placeholder="What does this agent do?"
              value={newDescription}
              onChange={(e) => setNewDescription(e.target.value)}
              onKeyDown={(e) => { if (e.key === "Enter") handleCreate(); }}
            />
          </div>
          <button
            className="appearance-none border-none bg-[var(--color-accent)] text-white rounded-lg px-4 py-2 text-[13px] font-medium cursor-pointer hover:opacity-90 self-start disabled:opacity-40 disabled:cursor-not-allowed"
            onClick={handleCreate}
            disabled={!newName.trim()}
          >
            Create Agent
          </button>
        </div>
      </section>

      {/* Agent list */}
      <section>
        <h3 className="text-[13px] font-semibold mb-4 pb-2.5 border-b border-[var(--color-border-subtle)] text-[var(--color-text-secondary)] uppercase tracking-wider">
          All Agents
        </h3>
        {agents.length === 0 ? (
          <p className="text-[13px] text-[var(--color-text-muted)]">No agents loaded yet.</p>
        ) : (
          <div className="flex flex-col gap-3">
            {agents.map((agent) => {
              const isProsca = agent.id === "prosca";
              const isConfirming = confirmDelete === agent.id;
              return (
                <div
                  key={agent.id}
                  className="border border-[var(--color-border)] rounded-lg bg-[var(--color-bg-elevated)] overflow-hidden"
                >
                  <div className="flex items-center justify-between px-4 py-3">
                    <div className="flex items-center gap-2">
                      <span className="text-[13px] font-semibold">{agent.id}</span>
                      {isProsca && (
                        <span className="text-[10px] text-[var(--color-text-muted)] border border-[var(--color-border)] rounded px-1.5 py-px">
                          default
                        </span>
                      )}
                    </div>
                    <div className="flex items-center gap-2">
                      {!isProsca && (
                        <button
                          className={`text-[12px] cursor-pointer bg-transparent border-none font-medium ${
                            isConfirming
                              ? "text-[var(--color-error)]"
                              : "text-[var(--color-text-muted)] hover:text-[var(--color-error)]"
                          }`}
                          onClick={() => handleDelete(agent.id)}
                        >
                          {isConfirming ? "Confirm delete?" : "Delete"}
                        </button>
                      )}
                      {isConfirming && (
                        <button
                          className="text-[12px] cursor-pointer bg-transparent border-none text-[var(--color-text-muted)] hover:text-[var(--color-text-secondary)]"
                          onClick={() => setConfirmDelete(null)}
                        >
                          Cancel
                        </button>
                      )}
                      {isProsca && (
                        <span className="text-[12px] text-[var(--color-text-muted)] italic">Cannot delete</span>
                      )}
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </section>
    </div>
  );
}
