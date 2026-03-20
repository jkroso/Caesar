import { createContext, useContext, useEffect, useState, useCallback, type ReactNode } from "react";
import { useSidecar } from "./SidecarContext";

interface SettingsContextValue {
  config: Record<string, unknown>;
  theme: "light" | "dark" | "system";
  setTheme: (theme: "light" | "dark" | "system") => void;
  updateConfig: (key: string, value: unknown) => void;
  refreshConfig: () => void;
}

const SettingsContext = createContext<SettingsContextValue | null>(null);

export function SettingsProvider({ children }: { children: ReactNode }) {
  const { send, onEvent, status } = useSidecar();
  const [config, setConfig] = useState<Record<string, unknown>>({});
  const [theme, setThemeState] = useState<"light" | "dark" | "system">("system");

  useEffect(() => {
    const unsubscribe = onEvent((event) => {
      if (event.type === "config") {
        setConfig(event.data);
      }
    });
    return unsubscribe;
  }, [onEvent]);

  const refreshConfig = useCallback(() => {
    if (status === "ready") {
      send({ type: "config_get" });
    }
  }, [send, status]);

  useEffect(() => {
    refreshConfig();
  }, [refreshConfig]);

  const updateConfig = useCallback((key: string, value: unknown) => {
    send({ type: "config_set", key, value });
    setConfig((prev) => ({ ...prev, [key]: value }));
  }, [send]);

  const setTheme = useCallback((t: "light" | "dark" | "system") => {
    setThemeState(t);
    localStorage.setItem("prosca-theme", t);
    const resolved = t === "system"
      ? (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light")
      : t;
    document.documentElement.setAttribute("data-theme", resolved);
  }, []);

  // Initialize theme
  useEffect(() => {
    const saved = localStorage.getItem("prosca-theme") as "light" | "dark" | "system" | null;
    if (saved) setTheme(saved);
  }, [setTheme]);

  return (
    <SettingsContext.Provider value={{ config, theme, setTheme, updateConfig, refreshConfig }}>
      {children}
    </SettingsContext.Provider>
  );
}

export function useSettings() {
  const ctx = useContext(SettingsContext);
  if (!ctx) throw new Error("useSettings must be used within SettingsProvider");
  return ctx;
}
