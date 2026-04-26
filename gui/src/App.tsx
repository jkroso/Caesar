import { useState } from "react";
import { PanelLeft } from "lucide-react";
import { SidecarProvider, useSidecar } from "@/contexts/SidecarContext";
import { ChatProvider } from "@/contexts/ChatContext";
import { ConversationProvider } from "@/contexts/ConversationContext";
import { SettingsProvider } from "@/contexts/SettingsContext";
import { ProjectProvider } from "@/contexts/ProjectContext";
import { RoutineProvider } from "@/contexts/RoutineContext";
import { AgentProvider } from "@/contexts/AgentContext";
import { CalcsProvider } from "@/contexts/CalcsContext";
import Sidebar from "@/components/layout/Sidebar";
import Header from "@/components/layout/Header";
import ChatPage from "@/pages/ChatPage";
import ProjectsPage from "@/pages/ProjectsPage";
import SkillsPage from "@/pages/SkillsPage";
import RoutinesPage from "@/pages/RoutinesPage";
import SettingsPage from "@/pages/SettingsPage";
import AgentsPage from "@/pages/AgentsPage";
import CalcsPage from "@/pages/CalcsPage";

type Page = "chat" | "projects" | "skills" | "routines" | "settings" | "agents" | "calcs";

function AppContent() {
  const [page, setPage] = useState<Page>("chat");
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const { status, restart } = useSidecar();

  const pageTitle = {
    chat: "Chat",
    projects: "Projects",
    skills: "Skills",
    routines: "Routines",
    settings: "Settings",
    agents: "Agents",
    calcs: "Calcs",
  }[page];

  return (
    <div className="flex h-full text-[var(--color-text)]">
      <Sidebar currentPage={page} onNavigate={setPage} open={sidebarOpen} />
      {/* Sidebar toggle — fixed next to macOS traffic lights, rendered after sidebar so it's on top */}
      <button
        className="fixed top-[5px] left-[80px] z-50 appearance-none border-none bg-transparent cursor-pointer flex items-center justify-center w-7 h-7 rounded-md text-[var(--color-text-muted)] hover:bg-[var(--color-bg-muted)] hover:text-[var(--color-text-secondary)]"
        onClick={() => setSidebarOpen(!sidebarOpen)}
      >
        <PanelLeft size={16} strokeWidth={1.75} />
      </button>
      <div className="flex-1 flex flex-col overflow-hidden">
        <Header title={pageTitle} sidebarOpen={sidebarOpen} />
        {status === "starting" && (
          <div className="flex flex-col items-center justify-center flex-1 gap-2 text-[var(--color-text-secondary)]">
            <div className="flex items-center gap-1">
              <span className="w-2 h-2 rounded-full bg-[var(--color-text-muted)] animate-[pulse-dot_1.4s_infinite]" />
              <span className="w-2 h-2 rounded-full bg-[var(--color-text-muted)] animate-[pulse-dot_1.4s_infinite]" style={{ animationDelay: "0.2s" }} />
              <span className="w-2 h-2 rounded-full bg-[var(--color-text-muted)] animate-[pulse-dot_1.4s_infinite]" style={{ animationDelay: "0.4s" }} />
            </div>
            <p>Starting Prosca agent...</p>
          </div>
        )}
        {status === "error" && (
          <div className="flex flex-col items-center justify-center flex-1 gap-3 text-[var(--color-text-secondary)]">
            <p className="text-[var(--color-error)] px-4 py-2">
              Sidecar disconnected
            </p>
            <button
              onClick={() => restart()}
              className="appearance-none border border-[var(--color-border)] bg-[var(--color-bg-muted)] hover:bg-[var(--color-bg-elevated)] text-sm px-3 py-1.5 rounded-md cursor-pointer text-[var(--color-text)]"
            >
              Reconnect
            </button>
          </div>
        )}
        {status === "ready" && (
          <>
            {page === "chat" && <ChatPage />}
            {page === "projects" && <ProjectsPage />}
            {page === "skills" && <SkillsPage />}
            {page === "routines" && <RoutinesPage />}
            {page === "settings" && <SettingsPage />}
            {page === "agents" && <AgentsPage />}
            {page === "calcs" && <CalcsPage />}
          </>
        )}
      </div>
    </div>
  );
}

export default function App() {
  return (
    <SidecarProvider>
      <SettingsProvider>
        <AgentProvider>
          <ConversationProvider>
            <ChatProvider>
              <ProjectProvider>
                <RoutineProvider>
                  <CalcsProvider>
                    <AppContent />
                  </CalcsProvider>
                </RoutineProvider>
              </ProjectProvider>
            </ChatProvider>
          </ConversationProvider>
        </AgentProvider>
      </SettingsProvider>
    </SidecarProvider>
  );
}
