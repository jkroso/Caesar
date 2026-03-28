import { useState, useRef, useEffect, useCallback, type KeyboardEvent } from "react";
import { ChevronDown, Search } from "lucide-react";
import type { ModelSearchResult, ProviderInfo } from "@/types/sidecar";
import { useSidecar } from "@/contexts/SidecarContext";
import { useSettings } from "@/contexts/SettingsContext";

export default function ModelSelector({ value, onChange, className, dropdownPosition = "above" }: {
  value?: string;
  onChange?: (modelId: string) => void;
  className?: string;
  dropdownPosition?: "above" | "below";
} = {}) {
  const { send, onEvent } = useSidecar();
  const { config } = useSettings();
  const [results, setResults] = useState<ModelSearchResult[]>([]);
  const [providerList, setProviderList] = useState<ProviderInfo[]>([]);
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [selectedId, setSelectedId] = useState<string>("");
  const [highlightIndex, setHighlightIndex] = useState(-1);
  const dropdownRef = useRef<HTMLDivElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const keyboardNavRef = useRef(false);

  useEffect(() => {
    if (value === undefined && config.llm && typeof config.llm === "string") setSelectedId(config.llm);
  }, [config.llm, value]);

  useEffect(() => {
    if (value !== undefined) setSelectedId(value || "");
  }, [value]);

  // Fetch providers once on mount
  useEffect(() => {
    return onEvent((event: any) => {
      if (event.type === "model_search_results") setResults(event.data);
      else if (event.type === "providers") setProviderList(event.data);
    });
  }, [onEvent]);

  useEffect(() => {
    send({ type: "providers_list" });
  }, [send]);

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

  useEffect(() => {
    if (open) { searchRef.current?.focus(); setHighlightIndex(-1); }
  }, [open]);

  useEffect(() => { setHighlightIndex(-1); }, [results]);

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

  useEffect(() => {
    if (!keyboardNavRef.current || highlightIndex < 0 || !listRef.current) return;
    const items = listRef.current.querySelectorAll("[data-model-item]");
    items[highlightIndex]?.scrollIntoView({ block: "nearest" });
    keyboardNavRef.current = false;
  }, [highlightIndex]);

  const handleKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    const count = results.length;
    if (!count) return;
    switch (e.key) {
      case "ArrowDown":
        e.preventDefault();
        keyboardNavRef.current = true;
        setHighlightIndex((prev) => (prev + 1) % count);
        break;
      case "ArrowUp":
        e.preventDefault();
        keyboardNavRef.current = true;
        setHighlightIndex((prev) => (prev <= 0 ? count - 1 : prev - 1));
        break;
      case "Enter":
        e.preventDefault();
        if (highlightIndex >= 0 && highlightIndex < count) handleSelect(results[highlightIndex]);
        break;
      case "Escape":
        e.preventDefault();
        setOpen(false);
        setSearch("");
        setHighlightIndex(-1);
        break;
    }
  };

  // Build provider lookup for logos/names
  const providerMap = new Map(providerList.map((p) => [p.id, p]));

  // Group results by provider, maintaining provider order from providerList
  const providerOrder = providerList.length > 0
    ? providerList.map((p) => p.id)
    : [...new Set(results.map((r) => r.provider))];

  const grouped = providerOrder
    .map((pid) => {
      const info = providerMap.get(pid);
      return {
        id: pid,
        name: info?.name || pid,
        logo: info?.logo || null,
        models: results.filter((m) => m.provider === pid),
      };
    })
    .filter((g) => g.models.length > 0);

  // Any providers in results not in providerOrder
  const knownIds = new Set(providerOrder);
  for (const r of results) {
    if (!knownIds.has(r.provider)) {
      knownIds.add(r.provider);
      grouped.push({
        id: r.provider,
        name: r.provider,
        logo: null,
        models: results.filter((m) => m.provider === r.provider),
      });
    }
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
        <div className={`absolute ${dropdownPosition === "above" ? "bottom-[calc(100%+4px)]" : "top-[calc(100%+4px)]"} right-0 w-80 max-h-[400px] bg-[var(--color-bg-elevated)] border border-[var(--color-border)] rounded-xl shadow-lg z-[100] flex flex-col overflow-hidden`}>
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
              <div key={group.id}>
                <div className="flex items-center gap-1.5 px-3 pt-2.5 pb-1">
                  {group.logo && (
                    <img src={group.logo} alt="" className="w-3.5 h-3.5" />
                  )}
                  <span className="text-[10px] font-semibold text-[var(--color-text-muted)] uppercase tracking-wider">
                    {group.name}
                  </span>
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
                {search ? "No models found" : "Loading..."}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
