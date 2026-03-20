import { useEffect, useRef, Fragment } from "react";
import { useChat } from "@/contexts/ChatContext";
import MessageItem from "./MessageItem";
import WorkingIndicator from "./WorkingIndicator";

export default function MessageList() {
  const { messages, agentBusy } = useChat();
  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, agentBusy]);

  // Find where to insert the working indicator:
  // After the last non-user message (agent response, tool result, error)
  let spinnerIndex = -1;
  if (agentBusy) {
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role !== "user") {
        spinnerIndex = i + 1;
        break;
      }
    }
    if (spinnerIndex === -1) spinnerIndex = 0;
  }

  return (
    <div className="flex-1 overflow-y-auto px-6 py-4 max-w-[800px] mx-auto w-full">
      {messages.map((msg, i) => (
        <Fragment key={i}>
          {i === spinnerIndex && <WorkingIndicator />}
          <MessageItem message={msg} />
        </Fragment>
      ))}
      {agentBusy && spinnerIndex >= messages.length && <WorkingIndicator />}
      <div ref={bottomRef} />
    </div>
  );
}
