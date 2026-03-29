import { useEffect, useRef } from "react";
import { useChat } from "@/contexts/ChatContext";
import MessageItem from "./MessageItem";
import WorkingIndicator from "./WorkingIndicator";

export default function MessageList() {
  const { messages, agentBusy } = useChat();
  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, agentBusy]);

  return (
    <div className="flex-1 overflow-y-auto px-6 py-4 max-w-[800px] mx-auto w-full">
      {messages.map((msg, i) => (
        <MessageItem key={i} message={msg} />
      ))}
      {agentBusy && <WorkingIndicator />}
      <div ref={bottomRef} />
    </div>
  );
}
