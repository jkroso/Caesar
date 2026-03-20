import { useState, useRef, useEffect, useCallback, type KeyboardEvent } from "react";
import { ChevronDown, Search } from "lucide-react";
import type { ModelInfo } from "@/types/sidecar";
import { useSidecar } from "@/contexts/SidecarContext";
import { useSettings } from "@/contexts/SettingsContext";

const PROVIDER_LABELS: Record<string, string> = {
  xai: "xAI (Grok)",
  anthropic: "Anthropic",
  google: "Google (Gemini)",
  openai: "OpenAI",
  ollama: "Local (Ollama)",
};

const PROVIDER_ORDER = ["xai", "anthropic", "google", "openai", "ollama"];

const CAPABILITIES = [
  { key: "text", label: "Text" },
  { key: "image", label: "Image" },
  { key: "coding", label: "Coding" },
  { key: "reasoning", label: "Reasoning" },
  { key: "tool", label: "Tools" },
] as const;

interface ModelSelectorProps {
  value?: string;
  onChange?: (modelId: string) => void;
  className?: string;
  dropdownPosition?: "above" | "below";
}

export default function ModelSelector({ value, onChange, className, dropdownPosition = "above" }: ModelSelectorProps = {}) {
  const { send } = useSidecar();
  const { config } = useSettings();
  const [models, setModels] = useState<ModelInfo[]>([]);
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [selectedId, setSelectedId] = useState<string>("");
  const [highlightIndex, setHighlightIndex] = useState(-1);
  const [activeFilters, setActiveFilters] = useState<string[]>([]);
  const dropdownRef = useRef<HTMLDivElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);

  const isControlled = value !== undefined;

  useEffect(() => {
    if (!isControlled && config.llm && typeof config.llm === "string") {
      setSelectedId(config.llm);
    }
  }, [config.llm, isControlled]);

  useEffect(() => {
    if (isControlled) {
      setSelectedId(value || "");
    }
  }, [value, isControlled]);

  const fetched = useRef(false);
  useEffect(() => {
    if (open && !fetched.current) {
      fetched.current = true;
      fetch("/api.json")
        .then((r) => r.json())
        .then((data) => {
          const allModels: ModelInfo[] = [];
          Object.entries(data).forEach(([prov, pData]) => {
            if (pData && typeof pData === "object" && "models" in pData) {
              const modelsObj = (pData as any).models;
              Object.entries(modelsObj).forEach(([k, mData]) => {
                const m = mData as any;
                allModels.push({
                  id: m.id || k,
                  name: m.name || k,
                  provider: prov,
                  family: m.family,
                  release_date: m.release_date || m.last_updated,
                  modalities: m.modalities,
                  reasoning: m.reasoning,
                  tool_call: m.tool_call,
                  cost: m.cost,
                });
              });
            }
          });
          return allModels;
        })
        .then((allModels) => {
          return fetch("http://localhost:11434/api/tags")
            .then((r) => (r.ok ? r.json() : { models: [] }))
            .catch(() => ({ models: [] }))
            .then((ollamaData) => {
              if (ollamaData.models) {
                ollamaData.models.forEach((om: any) => {
                  allModels.push({
                    id: `ollama:${om.name}`,
                    name: om.name,
                    provider: "ollama",
                    family: "ollama",
                  });
                });
              }
              let filtered = allModels.filter((m) => m.provider !== "openrouter" && m.provider !== "ollama-cloud");
              const groups = new Map<string, ModelInfo[]>();
              filtered.forEach((m) => {
                const fam = m.provider === "ollama" ? m.id : (m.family || "other");
                const key = m.provider + "|" + fam;
                if (!groups.has(key)) groups.set(key, []);
                groups.get(key)!.push(m);
              });
              const latest: ModelInfo[] = [];
              groups.forEach((group) => {
                group.sort((a: ModelInfo, b: ModelInfo) => {
                  const da = a.release_date ? new Date(a.release_date).getTime() : 0;
                  const db = b.release_date ? new Date(b.release_date).getTime() : 0;
                  return db - da;
                });
                latest.push(group[0]);
              });
              setModels(latest);
            });
        });
    }
  }, [open]);

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

  const searchFiltered = search
    ? models.filter((m) =>
        m.name.toLowerCase().includes(search.toLowerCase()) ||
        m.id.toLowerCase().includes(search.toLowerCase())
      )
    : models;
  const filtered = activeFilters.length === 0
    ? searchFiltered
    : searchFiltered.filter((m) => activeFilters.every((f) => {
        if (f === "text") return m.modalities?.input?.includes("text") ?? true;
        if (f === "image") return m.modalities?.input?.some((i) => ["image", "vision"].includes(i)) ?? false;
        if (f === "coding") return m.name.toLowerCase().includes("code") || (m.tool_call ?? false);
        if (f === "reasoning") return m.reasoning ?? false;
        if (f === "tool") return m.tool_call ?? false;
        return true;
      }));

  // Build flat list for keyboard nav
  const flatItems = filtered;

  useEffect(() => {
    setHighlightIndex(-1);
  }, [search, activeFilters]);

  const handleSelect = useCallback((model: ModelInfo) => {
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

  const toggleFilter = useCallback((key: string) => {
    setActiveFilters((prev) =>
      prev.includes(key) ? prev.filter((k) => k !== key) : [...prev, key]
    );
  }, []);

  // Scroll highlighted item into view
  useEffect(() => {
    if (highlightIndex < 0 || !listRef.current) return;
    const items = listRef.current.querySelectorAll("[data-model-item]");
    items[highlightIndex]?.scrollIntoView({ block: "nearest" });
  }, [highlightIndex]);

  const handleKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    const count = flatItems.length;
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
      case "Home":
        e.preventDefault();
        setHighlightIndex(0);
        break;
      case "End":
        e.preventDefault();
        setHighlightIndex(count - 1);
        break;
      case "Enter":
        e.preventDefault();
        if (highlightIndex >= 0 && highlightIndex < count) {
          handleSelect(flatItems[highlightIndex]);
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

  // Group by provider in defined order
  const grouped = PROVIDER_ORDER
    .map((provider) => ({
      provider,
      label: PROVIDER_LABELS[provider] || provider,
      models: filtered.filter((m) => m.provider === provider),
    }))
    .filter((g) => g.models.length > 0);

  const getItemIndex = (model: ModelInfo) => flatItems.indexOf(model);

  const displayName = models.find((m) => m.id === selectedId)?.name || selectedId || "Select model";

  return (
    <div className="relative" ref={dropdownRef}>
      <button
        className={className || "appearance-none border-none bg-transparent cursor-pointer flex items-center gap-1 text-[11px] text-[var(--color-text-muted)] px-2 py-1 rounded-lg hover:text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-muted)]"}
        onClick={() => setOpen(!open)}
        type="button"
        aria-haspopup="listbox"
        aria-expanded={open}
      >
        <span className="max-w-[180px] overflow-hidden text-ellipsis whitespace-nowrap">{displayName}</span>
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
              role="combobox"
              aria-expanded={open}
              aria-controls="model-listbox"
              aria-activedescendant={highlightIndex >= 0 ? `model-${flatItems[highlightIndex]?.id}` : undefined}
            />
          </div>
          <div className="flex gap-1 px-3 py-2 border-b border-[var(--color-border)] flex-wrap bg-[var(--color-bg-elevated)]">
            {CAPABILITIES.map(({ key, label }) => (
              <button
                key={key}
                onClick={() => toggleFilter(key)}
                className={`text-[10px] px-2.5 py-0.5 rounded-full border transition-all ${
                  activeFilters.includes(key)
                    ? "bg-[var(--color-accent)] text-white border-[var(--color-accent)]"
                    : "border-[var(--color-border)] hover:bg-[var(--color-bg-muted)] text-[var(--color-text-secondary)]"
                }`}
              >
                {label}
              </button>
            ))}
          </div>
          <div className="overflow-y-auto max-h-[350px] py-1" ref={listRef} role="listbox" id="model-listbox">
            {grouped.map((group) => (

               <div key={group.provider}>
                 <div className="flex items-center gap-1.5 px-3 pt-2.5 pb-1 text-[10px] font-semibold text-[var(--color-text-muted)] uppercase tracking-wider" role="presentation">
                   <img src={`/logos/${group.provider}.svg`} alt="" className="w-3.5 h-3.5 flex-shrink-0" />
                   {group.label}
                 </div>
                 {group.models.map((m) => {
                   const idx = getItemIndex(m);
                   const highlighted = idx === highlightIndex;
                   return (
                      <button
                        key={m.id}

                       id={`model-${m.id}`}
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
                       <div className="flex items-center justify-between w-full">
                         <span className="overflow-hidden text-ellipsis pr-2">{m.name}</span>
                          {m.cost && m.cost.input !== undefined && (
                            <span
                              className="text-[10px] font-mono text-[var(--color-text-muted)] shrink-0"
                              title={[
                                `Input: $${m.cost.input.toFixed(2)}/M`,
                                `Output: $${(m.cost.output ?? 0).toFixed(2)}/M`,
                                typeof m.cost.cache_read === "number" ? `Cache read: $${m.cost.cache_read.toFixed(2)}/M` : "",
                                typeof m.cost.cache_write === "number" ? `Cache write: $${m.cost.cache_write.toFixed(2)}/M` : "",
                                typeof m.cost.reasoning === "number" ? `Reasoning: $${m.cost.reasoning.toFixed(2)}/M` : "",
                                typeof m.cost.input_audio === "number" ? `Audio in: $${m.cost.input_audio.toFixed(2)}/M` : "",
                                typeof m.cost.output_audio === "number" ? `Audio out: $${m.cost.output_audio.toFixed(2)}/M` : "",
                              ].filter(Boolean).join("\n")}
                            >
                              ${Math.round(m.cost.input)}/${Math.round(m.cost.output ?? 0)}
                            </span>
                          )}

                       </div>
                     </button>

                  );
                })}
              </div>
            ))}
            {filtered.length === 0 && (
              <div className="p-3 text-xs text-[var(--color-text-muted)] text-center">No models found</div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
