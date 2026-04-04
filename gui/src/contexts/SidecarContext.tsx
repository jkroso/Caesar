import { createContext, useContext, useEffect, useRef, useState, useCallback, type ReactNode } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { SidecarEvent, SidecarStatus } from "@/types/sidecar";

interface SidecarContextValue {
  status: SidecarStatus;
  send: (msg: object) => Promise<void>;
  call: (msg: object) => Promise<any>;
  onEvent: (handler: (event: SidecarEvent) => void) => () => void;
  restart: () => Promise<void>;
}

const SidecarContext = createContext<SidecarContextValue | null>(null);

export function SidecarProvider({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<SidecarStatus>("disconnected");
  const handlersRef = useRef<Set<(event: SidecarEvent) => void>>(new Set());
  const readyRef = useRef(false);
  const queueRef = useRef<string[]>([]);
  const nextIdRef = useRef(0);
  const pendingRef = useRef<Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>>(new Map());

  const start = useCallback(async () => {
    setStatus("starting");
    try {
      await invoke("start_sidecar");
    } catch (e) {
      console.error("Failed to start sidecar:", e);
      setStatus("error");
    }
  }, []);

  const send = useCallback(async (msg: object) => {
    console.log("[Agent Input]", msg);
    const json = JSON.stringify(msg);
    if (!readyRef.current) {
      queueRef.current.push(json);
      return;
    }
    await invoke("send_to_sidecar", { message: json });
  }, []);

  const call = useCallback((msg: object): Promise<any> => {
    const id = ++nextIdRef.current;
    return new Promise((resolve, reject) => {
      pendingRef.current.set(id, { resolve, reject });
      send({ ...msg, id });
    });
  }, [send]);

  const onEvent = useCallback((handler: (event: SidecarEvent) => void) => {
    handlersRef.current.add(handler);
    return () => { handlersRef.current.delete(handler); };
  }, []);

  const restart = useCallback(async () => {
    readyRef.current = false;
    await invoke("stop_sidecar");
    await start();
  }, [start]);

  useEffect(() => {
    let cancelled = false;
    let unlistenMessage: UnlistenFn | undefined;
    let unlistenExit: UnlistenFn | undefined;

    const setup = async () => {
      const unlisten1 = await listen<string>("sidecar-message", (event) => {
        if (cancelled) return;
        try {
          const parsed: SidecarEvent = JSON.parse(event.payload);
          console.log("[Agent Output]", parsed);
          // Resolve pending RPC calls
          const rpcId = (parsed as any).id as number | undefined;
          if (rpcId != null) {
            const pending = pendingRef.current.get(rpcId);
            if (pending) {
              pendingRef.current.delete(rpcId);
              if (parsed.type === "error") {
                pending.reject(new Error(parsed.text));
              } else {
                pending.resolve(parsed);
              }
            }
          }
          if (parsed.type === "ready") {
            readyRef.current = true;
            setStatus("ready");
            // Flush queued messages
            const queued = queueRef.current.splice(0);
            for (const json of queued) {
              invoke("send_to_sidecar", { message: json }).catch(() => {});
            }
          }
          for (const handler of handlersRef.current) {
            handler(parsed);
          }
        } catch (e) {
          console.error("Failed to parse sidecar message:", e, event.payload);
        }
      });
      if (cancelled) { unlisten1(); return; }
      unlistenMessage = unlisten1;

      const unlisten2 = await listen("sidecar-exit", () => {
        if (cancelled) return;
        setStatus("error");
      });
      if (cancelled) { unlisten2(); return; }
      unlistenExit = unlisten2;

      await start();
    };

    setup();

    return () => {
      cancelled = true;
      unlistenMessage?.();
      unlistenExit?.();
      invoke("stop_sidecar");
    };
  }, [start]);

  return (
    <SidecarContext.Provider value={{ status, send, call, onEvent, restart }}>
      {children}
    </SidecarContext.Provider>
  );
}

export function useSidecar() {
  const ctx = useContext(SidecarContext);
  if (!ctx) throw new Error("useSidecar must be used within SidecarProvider");
  return ctx;
}
