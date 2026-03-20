import { useConversations } from "@/contexts/ConversationContext";

interface Props {
  onNavigateChat: () => void;
}

export default function HomePage({ onNavigateChat }: Props) {
  const { conversations, setActiveId, createConversation } = useConversations();

  const greeting = () => {
    const hour = new Date().getHours();
    if (hour < 12) return "Good morning!";
    if (hour < 17) return "Good afternoon!";
    return "Good evening!";
  };

  const handleNewChat = () => {
    createConversation();
    onNavigateChat();
  };

  const handleResume = (id: string) => {
    setActiveId(id);
    onNavigateChat();
  };

  return (
    <div className="flex-1 overflow-y-auto p-6 max-w-[900px] flex flex-col items-center pt-12">
      <div className="text-center mb-6">
        <h1 className="text-[28px] font-semibold mb-2">{greeting()}</h1>
        <p className="text-[var(--color-text-secondary)] text-sm">What would you like to work on?</p>
      </div>
      <button
        className="appearance-none border-none cursor-pointer px-6 py-3 rounded-xl bg-[var(--color-text)] text-[var(--color-bg)] text-sm font-medium mb-8 hover:opacity-90"
        onClick={handleNewChat}
      >
        Start a new conversation
      </button>
      {conversations.length > 0 && (
        <div className="w-full max-w-[900px]">
          <h3 className="text-sm font-medium mb-4">Recent conversations</h3>
          <div className="grid grid-cols-[repeat(auto-fill,minmax(280px,1fr))] gap-4">
            {conversations.slice(0, 6).map((conv) => (
              <div key={conv.id} className="border border-[var(--color-border)] rounded-xl p-4 cursor-pointer hover:border-[var(--color-info)] transition-colors" onClick={() => handleResume(conv.id)}>
                <h3 className="text-sm font-medium mb-1">{conv.title}</h3>
                <p className="text-xs text-[var(--color-text-muted)]">
                  {new Date(conv.updatedAt).toLocaleDateString()}
                </p>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
