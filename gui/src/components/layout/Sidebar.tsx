import { Plus, MessageSquare, Zap, Clock, Settings, Trash2, FolderOpen, Bot, Calculator } from "lucide-react";
import { useConversations } from "@/contexts/ConversationContext";
import { useAgents } from "@/contexts/AgentContext";
import { useSidecar } from "@/contexts/SidecarContext";
import { useProjects } from "@/contexts/ProjectContext";
import CalcsSidebarList from "@/components/calcs/CalcsSidebarList";

type Page = "chat" | "projects" | "skills" | "routines" | "settings" | "agents" | "calcs";

interface Props {
  currentPage: Page;
  onNavigate: (page: Page) => void;
  open: boolean;
}

const NAV_ITEMS: { page: Page; icon: typeof MessageSquare; label: string }[] = [
  { page: "projects", icon: FolderOpen, label: "Projects" },
  { page: "agents", icon: Bot, label: "Agents" },
  { page: "calcs", icon: Calculator, label: "Calcs" },
  { page: "skills", icon: Zap, label: "Skills" },
  { page: "routines", icon: Clock, label: "Routines" },
  { page: "settings", icon: Settings, label: "Settings" },
];

export default function Sidebar({ currentPage, onNavigate, open }: Props) {
  const { conversations, activeId, setActiveId, createConversation, deleteConversation } = useConversations();
  const { agents } = useAgents();
  const { status } = useSidecar();
  const { unseenCount } = useProjects();


  const handleSelectConversation = (id: string) => {
    setActiveId(id);
    onNavigate("chat");
  };

  // Sort agents: prosca first, then alphabetical
  const sortedAgents = [...agents].sort((a, b) => {
    if (a.id === "prosca") return -1;
    if (b.id === "prosca") return 1;
    return a.id.localeCompare(b.id);
  });

  // Group conversations by agentId, sorted newest first by creation time (stable order)
  const convsByAgent = (agentId: string) =>
    conversations
      .filter((c) => c.agentId === agentId)
      .sort((a, b) => b.createdAt - a.createdAt);

  // Collapsed icon-only rail
  if (!open) {
    return (
      <aside
        className="w-[52px] bg-[var(--color-bg-sidebar)] border-r border-[var(--color-border)] flex flex-col shrink-0 items-center"
      >
        {/* Drag region (window title bar area) */}
        <div className="h-[38px] shrink-0 w-full" data-tauri-drag-region="true" />

        {/* Nav icons */}
        <nav className="flex flex-col gap-1 pb-3">
          {NAV_ITEMS.map(({ page, icon: Icon, label }) => (
            <button
              key={page}
              onClick={() => onNavigate(page)}
              className={`group appearance-none border-none bg-transparent w-9 h-9 rounded-lg cursor-pointer flex items-center justify-center relative ${
                currentPage === page
                  ? "bg-[var(--color-bg-muted)] text-[var(--color-text)]"
                  : "text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-muted)] hover:text-[var(--color-text)]"
              }`}
            >
              <Icon size={16} strokeWidth={currentPage === page ? 2 : 1.75} />
              {page === "projects" && unseenCount > 0 && (
                <span className="absolute -top-0.5 -right-0.5 bg-[var(--color-accent)] text-white text-[7px] font-bold w-3.5 h-3.5 rounded-full flex items-center justify-center">
                  {unseenCount}
                </span>
              )}
              <span className="pointer-events-none absolute left-full ml-2 px-2 py-1 rounded-md bg-[var(--color-bg-elevated)] border border-[var(--color-border)] text-[11px] text-[var(--color-text)] font-medium whitespace-nowrap opacity-0 group-hover:opacity-100 shadow-sm z-50" style={{ transition: "opacity 120ms ease" }}>
                {label}
              </span>
            </button>
          ))}
        </nav>

        {/* Divider + Chat icon */}
        <div className="w-6 border-t border-[var(--color-border)] mb-2" />
        <button
          onClick={() => onNavigate("chat")}
          className={`group appearance-none border-none bg-transparent w-9 h-9 rounded-lg cursor-pointer flex items-center justify-center relative ${
            currentPage === "chat"
              ? "bg-[var(--color-bg-muted)] text-[var(--color-text)]"
              : "text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-muted)] hover:text-[var(--color-text)]"
          }`}
        >
          <MessageSquare size={16} strokeWidth={currentPage === "chat" ? 2 : 1.75} />
          <span className="pointer-events-none absolute left-full ml-2 px-2 py-1 rounded-md bg-[var(--color-bg-elevated)] border border-[var(--color-border)] text-[11px] text-[var(--color-text)] font-medium whitespace-nowrap opacity-0 group-hover:opacity-100 shadow-sm z-50" style={{ transition: "opacity 120ms ease" }}>
            Chat
          </span>
        </button>
        <button
          onClick={() => createConversation()}
          className="group appearance-none border-none bg-transparent w-9 h-9 rounded-lg cursor-pointer flex items-center justify-center relative text-[var(--color-text-muted)] hover:text-[var(--color-accent)] hover:bg-[var(--color-accent-soft)]"
        >
          <Plus size={16} strokeWidth={2} />
          <span className="pointer-events-none absolute left-full ml-2 px-2 py-1 rounded-md bg-[var(--color-bg-elevated)] border border-[var(--color-border)] text-[11px] text-[var(--color-text)] font-medium whitespace-nowrap opacity-0 group-hover:opacity-100 shadow-sm z-50" style={{ transition: "opacity 120ms ease" }}>
            New chat
          </span>
        </button>

        {/* Spacer */}
        <div className="flex-1" />

        {/* Status dot */}
        <div className="pb-4 pt-3 border-t border-[var(--color-border)] w-full flex justify-center" title={status === "ready" ? "Connected" : status}>
          <div
            className={`w-[7px] h-[7px] rounded-full ${
              status === "ready"
                ? "bg-[var(--color-success)]"
                : status === "starting"
                ? "bg-[var(--color-warning)]"
                : status === "error"
                ? "bg-[var(--color-error)]"
                : "bg-[var(--color-text-muted)]"
            }`}
            style={status === "ready" ? { boxShadow: "0 0 6px rgba(22, 163, 74, 0.4)" } : undefined}
          />
        </div>
      </aside>
    );
  }

  // Expanded full sidebar
  return (
    <aside
      className="w-[260px] bg-[var(--color-bg-sidebar)] border-r border-[var(--color-border)] flex flex-col shrink-0"
    >
      {/* Drag region (window title bar area) — split to leave gap for toggle button */}
      <div className="h-[38px] shrink-0 relative">
        <div className="absolute inset-0 right-[150px]" data-tauri-drag-region="true" />
        <div className="absolute top-0 bottom-0 left-[112px] right-0" data-tauri-drag-region="true" />
      </div>

      {/* Brand */}
      <div className="px-4 pb-3.5 flex items-center gap-2.5">
        <span className="font-semibold text-[15px] tracking-[-0.02em]">Prosca</span>
      </div>

      {/* Navigation */}
      <nav className="flex flex-col px-2.5 gap-0.5 pb-3">
        {NAV_ITEMS.map(({ page, icon: Icon, label }) => (
          <button
            key={page}
            onClick={() => onNavigate(page)}
            className={`appearance-none border-none bg-transparent px-2.5 py-[7px] rounded-lg cursor-pointer text-[13px] flex items-center gap-2.5 tracking-[-0.01em] ${
              currentPage === page
                ? "bg-[var(--color-bg-muted)] text-[var(--color-text)] font-medium"
                : "text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-muted)] hover:text-[var(--color-text)]"
            }`}
          >
            <Icon size={15} strokeWidth={currentPage === page ? 2 : 1.75} />
            <span>{label}</span>
            {page === "projects" && unseenCount > 0 && (
              <span className="bg-[var(--color-accent)] text-white text-[8px] font-bold px-1.5 py-px rounded-full ml-auto">
                {unseenCount}
              </span>
            )}
          </button>
        ))}
      </nav>

      {/* Calcs list — when calcs page is active */}
      {currentPage === "calcs" && (
        <div className="flex-1 overflow-y-auto pt-3 border-t border-[var(--color-border)]">
          <CalcsSidebarList onSelect={() => onNavigate("calcs")} />
        </div>
      )}

      {/* Conversations — grouped by agent (hidden on calcs page) */}
      {currentPage !== "calcs" && <div className="flex-1 overflow-y-auto px-2.5 pt-3 border-t border-[var(--color-border)]">
        {sortedAgents.map((agent) => {
          const agentConvs = convsByAgent(agent.id);
          return (
            <div key={agent.id} className="mb-3">
              {/* Agent header row */}
              <div className="flex items-center justify-between pr-0.5 mb-0.5">
                <span className="px-2.5 py-[5px] text-[11px] font-semibold text-[var(--color-text-muted)] uppercase tracking-wider flex-1 truncate">
                  {agent.id}
                </span>
                <button
                  className="appearance-none border-none bg-transparent cursor-pointer text-[var(--color-text-muted)] p-1.5 rounded-lg flex items-center hover:text-[var(--color-accent)] hover:bg-[var(--color-accent-soft)]"
                  onClick={() => { createConversation(agent.id); onNavigate("chat"); }}
                  title={`New chat with ${agent.id}`}
                >
                  <Plus size={13} strokeWidth={2} />
                </button>
              </div>

              {/* Conversations for this agent */}
              {agentConvs.map((conv) => (
                <div
                  key={conv.id}
                  className={`ml-2 py-[6px] px-2.5 rounded-lg cursor-pointer text-[12px] flex items-center justify-between relative group ${
                    activeId === conv.id
                      ? "bg-[var(--color-bg-muted)] text-[var(--color-text)]"
                      : "text-[var(--color-text-muted)] hover:bg-[var(--color-bg-muted)] hover:text-[var(--color-text-secondary)]"
                  }`}
                  onClick={() => handleSelectConversation(conv.id)}
                >
                  <span className="overflow-hidden text-ellipsis whitespace-nowrap flex-1">{conv.title}</span>
                  <button
                    className="appearance-none border-none bg-transparent cursor-pointer flex text-[var(--color-text-muted)] p-0.5 opacity-0 group-hover:opacity-100 hover:text-[var(--color-error)]"
                    onClick={(e) => { e.stopPropagation(); deleteConversation(conv.id); }}
                  >
                    <Trash2 size={12} />
                  </button>
                </div>
              ))}

              {agentConvs.length === 0 && (
                <p className="ml-2 px-2.5 text-[11px] text-[var(--color-text-muted)] italic py-1">No chats yet</p>
              )}
            </div>
          );
        })}

        {/* Fallback if no agents loaded yet */}
        {sortedAgents.length === 0 && (
          <p className="text-[11px] text-[var(--color-text-muted)] px-2.5 py-1">Loading agents...</p>
        )}
      </div>}

      {/* Status */}
      <div className="px-4 py-3 border-t border-[var(--color-border)] flex items-center gap-2">
        <div
          className={`w-[7px] h-[7px] rounded-full ${
            status === "ready"
              ? "bg-[var(--color-success)]"
              : status === "starting"
              ? "bg-[var(--color-warning)]"
              : status === "error"
              ? "bg-[var(--color-error)]"
              : "bg-[var(--color-text-muted)]"
          }`}
          style={status === "ready" ? { boxShadow: "0 0 6px rgba(22, 163, 74, 0.4)" } : undefined}
        />
        <span className="text-[11px] text-[var(--color-text-muted)] tracking-wide uppercase font-medium">
          {status === "ready" ? "Connected" : status}
        </span>
      </div>
    </aside>
  );
}
