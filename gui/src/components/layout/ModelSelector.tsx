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
  const [filters, setFilters] = useState<Set<string>>(new Set());
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
    // Fetch initial results so we can resolve provider logo for the current model
    send({ type: "model_search", query: "" });
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
    const count = filteredResults.length;
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
        if (highlightIndex >= 0 && highlightIndex < count) handleSelect(filteredResults[highlightIndex]);
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

  // Collect all available modalities from results
  const allModalities = new Set<string>();
  for (const r of results) {
    for (const m of r.modalities?.input ?? []) allModalities.add(m);
  }
  // Also include reasoning/tools as capability filters
  const capabilityTags = [...allModalities].sort();

  const toggleFilter = (tag: string) => {
    setFilters((prev) => {
      const next = new Set(prev);
      if (next.has(tag)) next.delete(tag); else next.add(tag);
      return next;
    });
    setHighlightIndex(-1);
  };

  // Filter results by selected capability filters
  const filteredResults = filters.size === 0 ? results : results.filter((m) => {
    for (const f of filters) {
      if (f === "reasoning" && !m.reasoning) return false;
      if (f === "tools" && !m.tool_call) return false;
      if (f !== "reasoning" && f !== "tools" && !(m.modalities?.input ?? []).includes(f)) return false;
    }
    return true;
  });

  // Group results by provider, maintaining provider order from providerList
  const providerOrder = providerList.length > 0
    ? providerList.map((p) => p.id)
    : [...new Set(filteredResults.map((r) => r.provider))];

  const grouped = providerOrder
    .map((pid) => {
      const info = providerMap.get(pid);
      return {
        id: pid,
        name: info?.name || pid,
        logo: info?.logo || null,
        models: filteredResults.filter((m) => m.provider === pid),
      };
    })
    .filter((g) => g.models.length > 0);

  // Any providers in results not in providerOrder
  const knownIds = new Set(providerOrder);
  for (const r of filteredResults) {
    if (!knownIds.has(r.provider)) {
      knownIds.add(r.provider);
      grouped.push({
        id: r.provider,
        name: r.provider,
        logo: null,
        models: filteredResults.filter((m) => m.provider === r.provider),
      });
    }
  }

  const getItemIndex = (model: ModelSearchResult) => filteredResults.indexOf(model);

  // Find logo for the selected model's provider
  const resolvedProvider = results.find((m) => m.id === selectedId)?.provider;
  const selectedLogo = resolvedProvider ? providerMap.get(resolvedProvider)?.logo ?? null : null;

  return (
    <div className="relative" ref={dropdownRef}>
      <button
        className={className || "appearance-none border-none bg-transparent cursor-pointer flex items-center gap-1 text-[11px] text-[var(--color-text-muted)] px-2 py-1 rounded-lg hover:text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-muted)]"}
        onClick={() => setOpen(!open)}
        type="button"
        aria-haspopup="listbox"
        aria-expanded={open}
        title={selectedId || "Select model"}
      >
        {!open && selectedLogo ? (
          <img src={selectedLogo} alt={resolvedProvider || ""} className="w-5 h-5 rounded-md bg-white/90 p-0.5" />
        ) : (
          <span className="max-w-[180px] overflow-hidden text-ellipsis whitespace-nowrap">{selectedId || "Select model"}</span>
        )}
        {!selectedLogo && !open && <ChevronDown size={12} />}
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
          {(capabilityTags.length > 0 || results.some(r => r.reasoning) || results.some(r => r.tool_call)) && (
            <div className="flex flex-wrap gap-1.5 px-3 py-2 border-b border-[var(--color-border)]">
              {capabilityTags.map((tag) => (
                <button
                  key={tag}
                  type="button"
                  onClick={() => toggleFilter(tag)}
                  className={`appearance-none border cursor-pointer rounded-full px-2 py-0.5 text-[10px] ${
                    filters.has(tag)
                      ? "bg-[var(--color-accent)] text-white border-[var(--color-accent)]"
                      : "bg-transparent text-[var(--color-text-muted)] border-[var(--color-border)] hover:border-[var(--color-text-muted)]"
                  }`}
                >{tag}</button>
              ))}
              {results.some(r => r.reasoning) && (
                <button
                  type="button"
                  onClick={() => toggleFilter("reasoning")}
                  className={`appearance-none border cursor-pointer rounded-full px-2 py-0.5 text-[10px] ${
                    filters.has("reasoning")
                      ? "bg-[var(--color-accent)] text-white border-[var(--color-accent)]"
                      : "bg-transparent text-[var(--color-text-muted)] border-[var(--color-border)] hover:border-[var(--color-text-muted)]"
                  }`}
                >reasoning</button>
              )}
              {results.some(r => r.tool_call) && (
                <button
                  type="button"
                  onClick={() => toggleFilter("tools")}
                  className={`appearance-none border cursor-pointer rounded-full px-2 py-0.5 text-[10px] ${
                    filters.has("tools")
                      ? "bg-[var(--color-accent)] text-white border-[var(--color-accent)]"
                      : "bg-transparent text-[var(--color-text-muted)] border-[var(--color-border)] hover:border-[var(--color-text-muted)]"
                  }`}
                >tools</button>
              )}
            </div>
          )}
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
            {filteredResults.length === 0 && (
              <div className="p-3 text-xs text-[var(--color-text-muted)] text-center">
                {search || filters.size > 0 ? "No models match" : "Loading..."}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
