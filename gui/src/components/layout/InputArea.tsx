import { useState, useRef, useCallback, useEffect, type KeyboardEvent } from "react";
import { Paperclip, X } from "lucide-react";
import { useChat } from "@/contexts/ChatContext";
import { useSidecar } from "@/contexts/SidecarContext";
import ModelSelector from "./ModelSelector";
import type { Attachment } from "@/types/message";
import type { SlashItem } from "@/types/sidecar";

interface Props {
  centered?: boolean;
}

function fileToAttachment(file: File): Promise<Attachment> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const base64 = (reader.result as string).split(",")[1];
      resolve({ mime: file.type, data: base64, name: file.name });
    };
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });
}

export default function InputArea({ centered }: Props) {
  const [text, setText] = useState("");
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [slashItems, setSlashItems] = useState<SlashItem[]>([]);
  const [slashState, setSlashState] = useState<{ query: string; start: number } | null>(null);
  const [slashIndex, setSlashIndex] = useState(0);
  const { sendMessage } = useChat();
  const { status, call } = useSidecar();
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const slashRef = useRef<HTMLDivElement>(null);

  // Focus textarea when window regains focus
  useEffect(() => {
    const onFocus = () => textareaRef.current?.focus();
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, []);

  // Fetch slash completions on mount
  useEffect(() => {
    call({ type: "slash_completions" }).then((res) => setSlashItems(res.data));
  }, [call]);

  // Filter items based on current slash token
  // Mid-message slash only shows skills (commands only work at start of input)
  const showSlash = slashState !== null;
  const midMessage = slashState !== null && slashState.start > 0;
  const filtered = slashState
    ? slashItems.filter((item) =>
        (!midMessage || item.kind === "skill") &&
        (item.name.toLowerCase().includes(slashState.query) || item.description.toLowerCase().includes(slashState.query)))
    : [];

  const handleSend = useCallback(() => {
    const trimmed = text.trim();
    if (!trimmed && attachments.length === 0) return;
    sendMessage(trimmed, attachments.length > 0 ? attachments : undefined);
    setText("");
    setAttachments([]);
    setSlashState(null);
    if (textareaRef.current) {
      textareaRef.current.style.height = "auto";
    }
  }, [text, attachments, sendMessage]);

  const selectSlashItem = useCallback((item: SlashItem) => {
    if (slashState) {
      const before = text.slice(0, slashState.start);
      const after = text.slice(slashState.start + slashState.query.length + 1); // +1 for the /
      setText(before + "/" + item.name + " " + after);
    } else {
      setText("/" + item.name + " ");
    }
    setSlashState(null);
    textareaRef.current?.focus();
  }, [text, slashState]);

  const handleKeyDown = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (showSlash && filtered.length > 0) {
      if (e.key === "ArrowDown") {
        e.preventDefault();
        setSlashIndex((i) => (i + 1) % filtered.length);
        return;
      }
      if (e.key === "ArrowUp") {
        e.preventDefault();
        setSlashIndex((i) => (i - 1 + filtered.length) % filtered.length);
        return;
      }
      if (e.key === "Tab" || (e.key === "Enter" && !e.shiftKey)) {
        e.preventDefault();
        selectSlashItem(filtered[slashIndex]);
        return;
      }
      if (e.key === "Escape") {
        e.preventDefault();
        setSlashState(null);
        return;
      }
    }
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSend();
    }
  };

  const handleInput = (e: React.ChangeEvent<HTMLTextAreaElement>) => {
    const val = e.target.value;
    setText(val);
    const el = e.target;
    el.style.height = "auto";
    el.style.height = Math.min(el.scrollHeight, 200) + "px";

    // Detect /token at cursor position
    const cursor = e.target.selectionStart ?? val.length;
    // Walk backwards from cursor to find a / that starts a token
    let slashPos = -1;
    for (let i = cursor - 1; i >= 0; i--) {
      if (val[i] === " " || val[i] === "\n") break;
      if (val[i] === "/") { slashPos = i; break; }
    }
    if (slashPos >= 0 && (slashPos === 0 || val[slashPos - 1] === " " || val[slashPos - 1] === "\n")) {
      const token = val.slice(slashPos + 1, cursor).toLowerCase();
      setSlashState({ query: token, start: slashPos });
      setSlashIndex(0);
    } else {
      setSlashState(null);
    }
  };

  const handleFiles = useCallback(async (files: FileList | File[]) => {
    const newAttachments = await Promise.all(
      Array.from(files).map(fileToAttachment)
    );
    setAttachments(prev => [...prev, ...newAttachments]);
  }, []);

  const handleFileInput = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    if (e.target.files?.length) {
      handleFiles(e.target.files);
      e.target.value = "";
    }
  }, [handleFiles]);

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    if (e.dataTransfer.files.length) {
      handleFiles(e.dataTransfer.files);
    }
  }, [handleFiles]);

  const handleDragOver = useCallback((e: React.DragEvent) => {
    e.preventDefault();
  }, []);

  const removeAttachment = useCallback((index: number) => {
    setAttachments(prev => prev.filter((_, i) => i !== index));
  }, []);

  // Scroll selected item into view
  useEffect(() => {
    if (showSlash && slashRef.current) {
      const el = slashRef.current.children[slashIndex] as HTMLElement | undefined;
      el?.scrollIntoView({ block: "nearest" });
    }
  }, [slashIndex, showSlash]);

  const disabled = status !== "ready";

  return (
    <div className={`p-3 px-4${centered ? " w-full max-w-[700px] mx-auto" : ""}`}>
      <div className="max-w-[800px] mx-auto relative">
        {/* Slash autocomplete popup */}
        {showSlash && filtered.length > 0 && (
          <div
            ref={slashRef}
            className="absolute bottom-full mb-1 left-0 right-0 bg-[var(--color-bg-elevated)] border border-[var(--color-border)] rounded-xl shadow-lg max-h-[240px] overflow-y-auto z-20 py-1"
          >
            {filtered.map((item, i) => (
              <button
                key={item.name}
                className="w-full text-left px-3 py-2 flex items-center gap-3 cursor-pointer border-none bg-transparent hover:bg-[var(--color-bg-muted)]"
                style={i === slashIndex ? { backgroundColor: "var(--color-accent-soft)", color: "var(--color-accent)" } : undefined}
                onMouseDown={(e) => { e.preventDefault(); selectSlashItem(item); }}
                onMouseEnter={() => setSlashIndex(i)}
              >
                <span className="text-[12px] font-mono text-[var(--color-accent)] shrink-0">/{item.name}</span>
                <span className="text-[11px] text-[var(--color-text-muted)] truncate">{item.description}</span>
                <span className={`text-[9px] px-1.5 py-px rounded-full ml-auto shrink-0 ${
                  item.kind === "command"
                    ? "bg-[var(--color-accent-soft)] text-[var(--color-accent)]"
                    : "bg-[var(--color-bg-muted)] text-[var(--color-text-muted)]"
                }`}>{item.kind}</span>
              </button>
            ))}
          </div>
        )}
        <div
          className="border border-[var(--color-border)] rounded-2xl bg-[var(--color-bg-elevated)] focus-within:border-[var(--color-accent)] py-3 px-4"
          style={{ transition: "border-color 200ms ease, box-shadow 200ms ease" }}
          onDrop={handleDrop}
          onDragOver={handleDragOver}
        >
          {attachments.length > 0 && (
            <div className="flex flex-wrap gap-2 mb-2">
              {attachments.map((att, i) => (
                <div key={i} className="relative group">
                  {att.mime.startsWith("image/") ? (
                    <img
                      src={`data:${att.mime};base64,${att.data}`}
                      alt={att.name}
                      className="h-16 w-16 object-cover rounded-lg border border-[var(--color-border)]"
                    />
                  ) : (
                    <div className="h-16 px-3 flex items-center gap-2 rounded-lg border border-[var(--color-border)] bg-[var(--color-bg-muted)] text-[11px] text-[var(--color-text-secondary)] max-w-[150px]">
                      <Paperclip size={12} />
                      <span className="truncate">{att.name}</span>
                    </div>
                  )}
                  <button
                    onClick={() => removeAttachment(i)}
                    className="absolute -top-1.5 -right-1.5 w-5 h-5 rounded-full bg-[var(--color-text)] text-[var(--color-bg)] flex items-center justify-center opacity-0 group-hover:opacity-100 cursor-pointer"
                    style={{ transition: "opacity 150ms ease" }}
                  >
                    <X size={10} strokeWidth={3} />
                  </button>
                </div>
              ))}
            </div>
          )}
          <div className="flex items-center gap-3">
            <input
              ref={fileInputRef}
              type="file"
              multiple
              className="hidden"
              onChange={handleFileInput}
              accept="image/*,audio/*,.pdf,.txt,.csv,.json,.md,.html,.xml,.yaml,.yml"
            />
            <button
              onClick={() => fileInputRef.current?.click()}
              disabled={disabled}
              className="appearance-none border-none bg-transparent p-0 text-[var(--color-text-muted)] hover:text-[var(--color-text)] cursor-pointer disabled:opacity-40 disabled:cursor-default shrink-0"
              title="Attach files"
            >
              <Paperclip size={16} />
            </button>
            <textarea
              ref={textareaRef}
              className="flex-1 border-none px-0 py-0 font-sans text-[13.5px] resize-none outline-none bg-transparent text-[var(--color-text)] min-h-[20px] max-h-[200px] disabled:opacity-40 leading-5 placeholder:text-[var(--color-text-muted)]"
              value={text}
              onChange={handleInput}
              onKeyDown={handleKeyDown}
              placeholder={disabled ? "Connecting to Prosca..." : "What's on your mind? Type / for commands"}
              disabled={disabled}
              rows={1}
            />
            <div className="flex items-center gap-2 shrink-0">
              <ModelSelector />
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
