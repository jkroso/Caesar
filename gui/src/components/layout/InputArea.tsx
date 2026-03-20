import { useState, useRef, useCallback, type KeyboardEvent } from "react";
import { ArrowUp } from "lucide-react";
import { useChat } from "@/contexts/ChatContext";
import { useSidecar } from "@/contexts/SidecarContext";
import ModelSelector from "./ModelSelector";

interface Props {
  centered?: boolean;
}

export default function InputArea({ centered }: Props) {
  const [text, setText] = useState("");
  const { sendMessage } = useChat();
  const { status } = useSidecar();
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const handleSend = useCallback(() => {
    const trimmed = text.trim();
    if (!trimmed) return;
    sendMessage(trimmed);
    setText("");
    if (textareaRef.current) {
      textareaRef.current.style.height = "auto";
    }
  }, [text, sendMessage]);

  const handleKeyDown = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSend();
    }
  };

  const handleInput = (e: React.ChangeEvent<HTMLTextAreaElement>) => {
    setText(e.target.value);
    const el = e.target;
    el.style.height = "auto";
    el.style.height = Math.min(el.scrollHeight, 200) + "px";
  };

  const disabled = status !== "ready";
  const canSend = text.trim().length > 0 && !disabled;

  return (
    <div className={`p-3 px-4${centered ? " w-full max-w-[700px] mx-auto" : ""}`}>
      <div className="max-w-[800px] mx-auto">
        <div
          className="border border-[var(--color-border)] rounded-2xl bg-[var(--color-bg-elevated)] focus-within:border-[var(--color-accent)] py-3 px-4"
          style={{ transition: "border-color 200ms ease, box-shadow 200ms ease" }}
        >
          <div className="flex items-center gap-3">
            <textarea
              ref={textareaRef}
              className="flex-1 border-none px-0 py-0 font-sans text-[13.5px] resize-none outline-none bg-transparent text-[var(--color-text)] min-h-[20px] max-h-[200px] disabled:opacity-40 leading-5 placeholder:text-[var(--color-text-muted)]"
              value={text}
              onChange={handleInput}
              onKeyDown={handleKeyDown}
              placeholder={disabled ? "Connecting to Prosca..." : "What's on your mind?"}
              disabled={disabled}
              rows={1}
            />
            <div className="flex items-center gap-2 shrink-0">
              <ModelSelector />
              <button
                onClick={handleSend}
                disabled={!canSend}
                className={`appearance-none border-none w-7 h-7 rounded-lg flex items-center justify-center cursor-pointer ${
                  canSend
                    ? "bg-[var(--color-accent)] text-white hover:bg-[var(--color-accent-hover)]"
                    : "bg-[var(--color-bg-muted)] text-[var(--color-text-muted)] cursor-default"
                }`}
                style={{ transition: "background-color 150ms ease, transform 100ms ease" }}
              >
                <ArrowUp size={14} strokeWidth={2.5} />
              </button>
            </div>
          </div>
        </div>
        <div className="flex justify-end mt-1.5 px-1">
          <span className="text-[10px] text-[var(--color-text-muted)] tracking-wide">
            Enter to send &middot; Shift+Enter for newline
          </span>
        </div>
      </div>
    </div>
  );
}
