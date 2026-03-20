import { useState } from "react";
import { useSettings } from "@/contexts/SettingsContext";
import ModelSelector from "@/components/layout/ModelSelector";

const GATEWAY_TYPES = [
  { id: "telegram", label: "Telegram", fields: [
    { key: "bot_token", label: "Bot Token", type: "password" as const, placeholder: "123456:ABC-DEF..." },
    { key: "chat_id", label: "Chat ID", type: "number" as const, placeholder: "-1001234567890" },
    { key: "owner_id", label: "Owner ID", type: "number" as const, placeholder: "12345678" },
  ]},
] as const;

type GatewayConfig = Record<string, Record<string, unknown>>;

export default function SettingsPage() {
  const { config, theme, setTheme, updateConfig } = useSettings();
  const [showTokens, setShowTokens] = useState<Record<string, boolean>>({});
  const [addMenuOpen, setAddMenuOpen] = useState(false);

  const inputClass = "border border-[var(--color-border)] rounded-lg px-3 py-1.5 text-[13px] font-mono bg-[var(--color-bg-elevated)] text-[var(--color-text)] min-w-[220px] outline-none focus:border-[var(--color-accent)]";

  // Gateway helpers
  const gateway = (config.gateway ?? {}) as GatewayConfig & { idle_threshold_mins?: number };
  const configuredTypes = GATEWAY_TYPES.filter(t => t.id in gateway);
  const availableTypes = GATEWAY_TYPES.filter(t => !(t.id in gateway));

  function updateGateway(newGateway: Record<string, unknown>) {
    updateConfig("gateway", newGateway);
  }

  function updateGatewayField(type: string, field: string, value: unknown) {
    const current = { ...gateway };
    current[type] = { ...(current[type] || {}), [field]: value };
    updateGateway(current);
  }

  function addGateway(typeId: string) {
    const current = { ...gateway };
    current[typeId] = {};
    updateGateway(current);
    setAddMenuOpen(false);
  }

  function deleteGateway(typeId: string) {
    const current = { ...gateway };
    delete current[typeId];
    updateGateway(current);
  }

  function updateIdleThreshold(mins: number) {
    const current = { ...gateway };
    (current as Record<string, unknown>).idle_threshold_mins = mins;
    updateGateway(current);
  }

  return (
    <div className="flex-1 overflow-y-auto p-6 max-w-[900px]" style={{ animation: "fadeIn 300ms ease" }}>
      <h2 className="text-[18px] font-semibold tracking-[-0.02em] mb-6">Settings</h2>

      <section className="mb-8">
        <h3 className="text-[13px] font-semibold mb-4 pb-2.5 border-b border-[var(--color-border-subtle)] text-[var(--color-text-secondary)] uppercase tracking-wider">
          Appearance
        </h3>
        <div className="flex items-center justify-between py-2.5">
          <label className="text-[13px] text-[var(--color-text-secondary)]">Theme</label>
          <div className="flex border border-[var(--color-border)] rounded-lg overflow-hidden">
            {(["light", "dark", "system"] as const).map((t) => (
              <button
                key={t}
                className={`appearance-none border-none px-4 py-1.5 text-[12px] cursor-pointer font-medium tracking-wide ${
                  theme === t
                    ? "bg-[var(--color-accent)] text-white"
                    : "bg-transparent text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-muted)]"
                }`}
                onClick={() => setTheme(t)}
              >
                {t.charAt(0).toUpperCase() + t.slice(1)}
              </button>
            ))}
          </div>
        </div>
      </section>

      <section className="mb-8">
        <h3 className="text-[13px] font-semibold mb-4 pb-2.5 border-b border-[var(--color-border-subtle)] text-[var(--color-text-secondary)] uppercase tracking-wider">
          LLM Configuration
        </h3>
        <div className="flex flex-col gap-1">
          <div className="flex items-center justify-between py-2.5">
            <label className="text-[13px] text-[var(--color-text-secondary)]">Model</label>
            <ModelSelector
              className="appearance-none border border-[var(--color-border)] rounded-lg px-3 py-1.5 text-[13px] font-sans bg-[var(--color-bg-elevated)] text-[var(--color-text)] min-w-[220px] outline-none cursor-pointer flex items-center justify-between gap-2 hover:border-[var(--color-accent)]"
              dropdownPosition="below"
            />
          </div>
          <div className="flex items-center justify-between py-2.5">
            <label className="text-[13px] text-[var(--color-text-secondary)]">Temperature</label>
            <input
              className={inputClass}
              type="number"
              step="0.1"
              min="0"
              max="2"
              value={String(config.temperature ?? 0.7)}
              onChange={(e) => updateConfig("temperature", parseFloat(e.target.value))}
            />
          </div>
          <div className="flex items-center justify-between py-2.5">
            <label className="text-[13px] text-[var(--color-text-secondary)]">Max Steps</label>
            <input
              className={inputClass}
              type="number"
              min="1"
              max="50"
              value={String(config.max_steps ?? 15)}
              onChange={(e) => updateConfig("max_steps", parseInt(e.target.value))}
            />
          </div>
          <div className="flex items-center justify-between py-2.5">
            <label className="text-[13px] text-[var(--color-text-secondary)]">Log Level</label>
            <div className="flex border border-[var(--color-border)] rounded-lg overflow-hidden">
              {(["debug", "info", "warn", "error"] as const).map((level) => (
                <button
                  key={level}
                  className={`appearance-none border-none px-4 py-1.5 text-[12px] cursor-pointer font-medium tracking-wide ${
                    String(config.log_level || "info") === level
                      ? "bg-[var(--color-accent)] text-white"
                      : "bg-transparent text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-muted)]"
                  }`}
                  onClick={() => updateConfig("log_level", level)}
                >
                  {level.charAt(0).toUpperCase() + level.slice(1)}
                </button>
              ))}
            </div>
          </div>
        </div>
      </section>

      <section className="mb-8">
        <h3 className="text-[13px] font-semibold mb-4 pb-2.5 border-b border-[var(--color-border-subtle)] text-[var(--color-text-secondary)] uppercase tracking-wider">
          Gateways
        </h3>

        <div className="flex items-center justify-between py-2.5 mb-2">
          <label className="text-[13px] text-[var(--color-text-secondary)]">Idle Threshold</label>
          <div className="flex items-center gap-2">
            <input
              className={inputClass + " min-w-[80px]"}
              type="number"
              min="1"
              max="120"
              value={String(gateway.idle_threshold_mins ?? 15)}
              onChange={(e) => updateIdleThreshold(parseInt(e.target.value))}
            />
            <span className="text-[12px] text-[var(--color-text-muted)]">minutes</span>
          </div>
        </div>

        <div className="flex flex-col gap-3 mt-3">
          {configuredTypes.map((gwType) => {
            const gwConfig = gateway[gwType.id] || {};
            return (
              <div
                key={gwType.id}
                className="border border-[var(--color-border)] rounded-lg bg-[var(--color-bg-elevated)] overflow-hidden"
              >
                <div className="flex items-center justify-between px-4 py-2.5 border-b border-[var(--color-border)]">
                  <span className="text-[13px] font-semibold">{gwType.label}</span>
                  <button
                    className="text-[11px] text-[var(--color-error)] hover:opacity-80 cursor-pointer bg-transparent border-none"
                    onClick={() => deleteGateway(gwType.id)}
                  >
                    Remove
                  </button>
                </div>
                <div className="px-4 py-2 flex flex-col gap-1">
                  {gwType.fields.map((field) => (
                    <div key={field.key} className="flex items-center justify-between py-2">
                      <label className="text-[13px] text-[var(--color-text-secondary)]">{field.label}</label>
                      {field.type === "password" ? (
                        <div className="flex items-center gap-1.5">
                          <input
                            className={inputClass}
                            type={showTokens[gwType.id] ? "text" : "password"}
                            placeholder={field.placeholder}
                            value={String(gwConfig[field.key] ?? "")}
                            onChange={(e) => updateGatewayField(gwType.id, field.key, e.target.value)}
                          />
                          <button
                            className="text-[11px] text-[var(--color-text-muted)] hover:text-[var(--color-text-secondary)] cursor-pointer bg-transparent border-none whitespace-nowrap"
                            onClick={() => setShowTokens(s => ({ ...s, [gwType.id]: !s[gwType.id] }))}
                          >
                            {showTokens[gwType.id] ? "Hide" : "Show"}
                          </button>
                        </div>
                      ) : (
                        <input
                          className={inputClass}
                          type="text"
                          placeholder={field.placeholder}
                          value={String(gwConfig[field.key] ?? "")}
                          onChange={(e) => {
                            const v = e.target.value;
                            const num = Number(v);
                            updateGatewayField(gwType.id, field.key, v !== "" && !isNaN(num) ? num : v);
                          }}
                        />
                      )}
                    </div>
                  ))}
                </div>
              </div>
            );
          })}
        </div>

        {availableTypes.length > 0 && (
          <div className="relative mt-3">
            <button
              className="text-[13px] text-[var(--color-accent)] hover:opacity-80 cursor-pointer bg-transparent border-none font-medium"
              onClick={() => setAddMenuOpen(!addMenuOpen)}
            >
              + Add Gateway
            </button>
            {addMenuOpen && (
              <>
                <div className="fixed inset-0 z-10" onClick={() => setAddMenuOpen(false)} />
                <div className="absolute left-0 top-full mt-1 z-20 bg-[var(--color-bg-elevated)] border border-[var(--color-border)] rounded-lg shadow-lg overflow-hidden min-w-[160px]">
                  {availableTypes.map((t) => (
                    <button
                      key={t.id}
                      className="w-full text-left px-4 py-2 text-[13px] cursor-pointer bg-transparent border-none text-[var(--color-text)] hover:bg-[var(--color-bg-muted)]"
                      onClick={() => addGateway(t.id)}
                    >
                      {t.label}
                    </button>
                  ))}
                </div>
              </>
            )}
          </div>
        )}

        {configuredTypes.length === 0 && !addMenuOpen && (
          <p className="text-[12px] text-[var(--color-text-muted)] mt-2">
            No gateways configured. Add one to enable remote access via Telegram or other messaging platforms.
          </p>
        )}
      </section>
    </div>
  );
}
