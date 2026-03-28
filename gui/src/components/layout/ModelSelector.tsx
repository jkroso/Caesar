import { useState, useRef, useEffect, useCallback, type KeyboardEvent } from "react";
import { ChevronDown, Search } from "lucide-react";
import type { ModelSearchResult } from "@/types/sidecar";
import { useSidecar } from "@/contexts/SidecarContext";
import { useSettings } from "@/contexts/SettingsContext";

const PROVIDER_LABELS: Record<string, string> = {
  xai: "xAI",
  anthropic: "Anthropic",
  google: "Google",
  openai: "OpenAI",
  mistral: "Mistral",
  deepseek: "DeepSeek",
  ollama: "Ollama",
};

const PROVIDER_ORDER = ["xai", "anthropic", "google", "openai", "mistral", "deepseek", "ollama"];

interface ModelSelectorProps {
  value?: string;
  onChange?: (modelId: string) => void;
  className?: string;
  dropdownPosition?: "above" | "below";
}

export default function ModelSelector({ value, onChange, className, dropdownPosition = "above" }: Partial<ModelSelectorProps> = {}) {
  const { send, onEvent } = useSidecar();
  const { config } = useSettings();
  const [results, setResults] = useState<ModelSearchResult[]>([]);
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [selectedId, setSelectedId] = useState<string>("");
  const [highlightIndex, setHighlightIndex] = useState(-1);
  const dropdownRef = useRef<HTMLDivElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const isControlled = value !== undefined;

  useEffect(() => {
    if (!isControlled && config.llm && typeof config.llm === "string") {
      setSelectedId(config.llm);
    }
  }, [config.llm, isControlled]);

  useEffect(() => {
    if (isControlled) setSelectedId(value || "");
  }, [value, isControlled]);

  // Listen for search results from backend
  useEffect(() => {
    return onEvent((event: any) => {
      if (event.type === "model_search_results") {
        setResults(event.data);
      }
    });
  }, [onEvent]);

  // Send search when query changes (debounced)
  useEffect(() => {
    if (!open) return;
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => {
      send({ type: "model_search", query: search || "" });
    }, search ? 150 : 0);
    return () => { if (debounceRef.current) clearTimeout(debounceRef.current); };
  }, [search, open, send]);

  // Close on outside click
  useEffect(() => {
    if (!open) return;
    const handleClick = (e: MouseEvent) => {
      if (dropdownRef.current && !dropdownRef.current.contains(e.target as Node)) {
        setOpen(false);
        setSearch("");
        setHighlightIndex(-1);
      }
    };
    document.addEventListener("mousedown", handleClick);
    return () => document.removeEventListener("mousedown", handleClick);
  }, [open]);

  // Focus search when opened
  useEffect(() => {
    if (open) {
      searchRef.current?.focus();
      setHighlightIndex(-1);
    }
  }, [open]);

  useEffect(() => {
    setHighlightIndex(-1);
  }, [results]);

  const handleSelect = useCallback((model: ModelSearchResult) => {
    setSelectedId(model.id);
    if (onChange) {
      onChange(model.id);
    } else {
      send({ type: "config_set", key: "llm", value: model.id });
    }
    setOpen(false);
    setSearch("");
    setHighlightIndex(-1);
  }, [send, onChange]);

  // Scroll highlighted item into view
  useEffect(() => {
    if (highlightIndex < 0 || !listRef.current) return;
    const items = listRef.current.querySelectorAll("[data-model-item]");
    items[highlightIndex]?.scrollIntoView({ block: "nearest" });
  }, [highlightIndex]);

  const handleKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    const count = results.length;
    if (!count) return;
    switch (e.key) {
      case "ArrowDown":
        e.preventDefault();
        setHighlightIndex((prev) => (prev + 1) % count);
        break;
      case "ArrowUp":
        e.preventDefault();
        setHighlightIndex((prev) => (prev <= 0 ? count - 1 : prev - 1));
        break;
      case "Enter":
        e.preventDefault();
        if (highlightIndex >= 0 && highlightIndex < count) {
          handleSelect(results[highlightIndex]);
        }
        break;
      case "Escape":
        e.preventDefault();
        setOpen(false);
        setSearch("");
        setHighlightIndex(-1);
        break;
    }
  };

  // Group by provider
  const grouped = PROVIDER_ORDER
    .map((provider) => ({
      provider,
      label: PROVIDER_LABELS[provider] || provider,
      models: results.filter((m) => m.provider === provider),
    }))
    .filter((g) => g.models.length > 0);

  // Add any providers not in PROVIDER_ORDER
  const knownProviders = new Set(PROVIDER_ORDER);
  const extraProviders = [...new Set(results.map(m => m.provider))].filter(p => !knownProviders.has(p));
  for (const p of extraProviders) {
    grouped.push({
      provider: p,
      label: PROVIDER_LABELS[p] || p,
      models: results.filter(m => m.provider === p),
    });
  }

  const getItemIndex = (model: ModelSearchResult) => results.indexOf(model);

  return (
    <div className="relative" ref={dropdownRef}>
      <button
        className={className || "appearance-none border-none bg-transparent cursor-pointer flex items-center gap-1 text-[11px] text-[var(--color-text-muted)] px-2 py-1 rounded-lg hover:text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-muted)]"}
        onClick={() => setOpen(!open)}
        type="button"
        aria-haspopup="listbox"
        aria-expanded={open}
      >
        <span className="max-w-[180px] overflow-hidden text-ellipsis whitespace-nowrap">{selectedId || "Select model"}</span>
        <ChevronDown size={12} />
      </button>
      {open && (
        <div className={`absolute ${dropdownPosition === "above" ? "bottom-[calc(100%+4px)]" : "top-[calc(100%+4px)]"} left-0 w-80 max-h-[400px] bg-[var(--color-bg-elevated)] border border-[var(--color-border)] rounded-xl shadow-lg z-[100] flex flex-col overflow-hidden`}>
          <div className="flex items-center gap-2 px-3 py-2 border-b border-[var(--color-border)] text-[var(--color-text-muted)]">
            <Search size={12} />
            <input
              ref={searchRef}
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="Search models..."
              className="appearance-none border-none bg-transparent flex-1 text-xs text-[var(--color-text)] outline-none"
            />
          </div>
          <div className="overflow-y-auto max-h-[350px] py-1" ref={listRef} role="listbox">
            {grouped.map((group) => (
              <div key={group.provider}>
                <div className="flex items-center gap-1.5 px-3 pt-2.5 pb-1 text-[10px] font-semibold text-[var(--color-text-muted)] uppercase tracking-wider">
                  {group.label}
                </div>
                {group.models.map((m) => {
                  const idx = getItemIndex(m);
                  const highlighted = idx === highlightIndex;
                  const flags: string[] = [];
                  if (m.reasoning) flags.push("reasoning");
                  if (m.tool_call) flags.push("tools");
                  return (
                    <button
                      key={m.id}
                      data-model-item
                      role="option"
                      aria-selected={m.id === selectedId}
                      className={`appearance-none border-none bg-transparent cursor-pointer block w-full box-border px-6 py-1.5 text-xs whitespace-nowrap overflow-hidden text-ellipsis text-left transition-colors${
                        highlighted ? " bg-[var(--color-bg-muted)] text-[var(--color-text)]" : ""
                      }${!highlighted ? " hover:bg-[var(--color-bg-muted)] hover:text-[var(--color-text)]" : ""}${
                        m.id === selectedId ? " text-[var(--color-accent)] font-medium" : highlighted ? "" : " text-[var(--color-text-secondary)]"
                      }`}
                      onClick={() => handleSelect(m)}
                      onMouseEnter={() => setHighlightIndex(idx)}
                      type="button"
                    >
                      <div className="flex items-center justify-between w-full gap-2">
                        <span className="overflow-hidden text-ellipsis">{m.name}</span>
                        <span className="flex items-center gap-2 shrink-0">
                          {flags.length > 0 && (
                            <span className="text-[9px] text-[var(--color-text-muted)]">{flags.join(", ")}</span>
                          )}
                          {m.cost && m.cost.input !== undefined && (
                            <span className="text-[10px] font-mono text-[var(--color-text-muted)]">
                              ${Math.round(m.cost.input)}/${Math.round(m.cost.output ?? 0)}
                            </span>
                          )}
                        </span>
                      </div>
                    </button>
                  );
                })}
              </div>
            ))}
            {results.length === 0 && (
              <div className="p-3 text-xs text-[var(--color-text-muted)] text-center">
                {search ? "No models found" : "Type to search models..."}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
