import { useChat } from "@/contexts/ChatContext";
import MessageList from "@/components/messages/MessageList";
import InputArea from "@/components/layout/InputArea";

export default function ChatPage() {
  const { messages } = useChat();
  const isEmpty = messages.length === 0;

  if (isEmpty) {
    return (
      <div className="flex flex-col flex-1 overflow-hidden justify-center items-center">
        <div className="mb-6 text-center" style={{ animation: "fadeIn 400ms ease" }}>
          <h2 className="text-[22px] font-semibold tracking-[-0.03em] text-[var(--color-text)] mb-1.5">
            What can I help with?
          </h2>
          <p className="text-[13px] text-[var(--color-text-muted)]">
            Ask anything, or describe a task to get started.
          </p>
        </div>
        <InputArea centered />
      </div>
    );
  }

  return (
    <div className="flex flex-col flex-1 overflow-hidden">
      <div className="flex-1 overflow-hidden flex">
        <MessageList />
      </div>
      <InputArea />
    </div>
  );
}
