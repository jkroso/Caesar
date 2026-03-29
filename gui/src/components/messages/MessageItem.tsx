import { Paperclip } from "lucide-react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeHighlight from "rehype-highlight";
import julia from "highlight.js/lib/languages/julia";
import ToolApprovalCard from "./ToolApprovalCard";
import ActivityBlock from "./ActivityBlock";
import type { ChatMessage } from "@/types/message";

const rehypeHighlightOptions = { languages: { julia } };

interface Props {
  message: ChatMessage;
}

export default function MessageItem({ message }: Props) {
  switch (message.role) {
    case "user":
      return (
        <div className="mb-5 flex justify-end" style={{ animation: "fadeIn 200ms ease forwards" }}>
          <div className="bg-[var(--color-accent)] text-white px-3.5 py-2 rounded-2xl rounded-br-md max-w-[70%] text-[13.5px] leading-relaxed">
            {message.attachments && message.attachments.length > 0 && (
              <div className="flex flex-wrap gap-1.5 mb-2">
                {message.attachments.map((att, i) =>
                  att.mime.startsWith("image/") ? (
                    <img
                      key={i}
                      src={`data:${att.mime};base64,${att.data}`}
                      alt={att.name}
                      className="max-h-40 rounded-lg"
                    />
                  ) : (
                    <div key={i} className="flex items-center gap-1.5 bg-white/20 rounded-md px-2 py-1 text-[11px]">
                      <Paperclip size={10} />
                      <span className="truncate max-w-[120px]">{att.name}</span>
                    </div>
                  )
                )}
              </div>
            )}
            {message.text && <div className="whitespace-pre-wrap">{message.text}</div>}
          </div>
        </div>
      );

    case "agent":
      return (
        <div className="mb-5 prose-agent" style={{ animation: "fadeIn 250ms ease forwards" }}>
          <ReactMarkdown remarkPlugins={[remarkGfm]} rehypePlugins={[[rehypeHighlight, rehypeHighlightOptions]]}>
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

    case "activity":
      return <ActivityBlock steps={message.steps} collapsed={message.collapsed} inputTokens={message.inputTokens} outputTokens={message.outputTokens} />;

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
