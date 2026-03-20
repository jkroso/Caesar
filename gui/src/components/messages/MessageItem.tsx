import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeHighlight from "rehype-highlight";
import ToolApprovalCard from "./ToolApprovalCard";
import type { ChatMessage } from "@/types/message";

interface Props {
  message: ChatMessage;
}

export default function MessageItem({ message }: Props) {
  switch (message.role) {
    case "user":
      return (
        <div className="mb-5 flex justify-end" style={{ animation: "fadeIn 200ms ease forwards" }}>
          <div className="bg-[var(--color-accent)] text-white px-3.5 py-2 rounded-2xl rounded-br-md max-w-[70%] whitespace-pre-wrap text-[13.5px] leading-relaxed">
            {message.text}
          </div>
        </div>
      );

    case "agent":
      return (
        <div className="mb-5 prose-agent" style={{ animation: "fadeIn 250ms ease forwards" }}>
          <ReactMarkdown remarkPlugins={[remarkGfm]} rehypePlugins={[rehypeHighlight]}>
            {message.text}
          </ReactMarkdown>
        </div>
      );

    case "tool_request":
      return (
        <div className="mb-4" style={{ animation: "fadeIn 200ms ease forwards" }}>
          <ToolApprovalCard
            id={message.id}
            name={message.name}
            args={message.args}
            decision={message.decision}
          />
        </div>
      );

    case "tool_result":
      return null;

    case "error":
      return (
        <div className="mb-4 text-[var(--color-error)] text-xs" style={{ animation: "fadeIn 200ms ease forwards" }}>
          <div className="bg-[color-mix(in_srgb,var(--color-error)_8%,transparent)] border border-[color-mix(in_srgb,var(--color-error)_20%,transparent)] rounded-xl px-3.5 py-2.5">
            {message.text}
          </div>
        </div>
      );
  }
}
