import { createContext, useContext, useEffect, useReducer, useCallback, ReactNode, useMemo } from "react";
import { useSidecar } from "@/contexts/SidecarContext";
import type {
  Calc,
  CalcIndexEntry,
  CalcParagraph,
  SidecarEvent,
} from "@/types/sidecar";

interface State {
  index: CalcIndexEntry[];
  calcs: Record<string, Calc>;
  activeId: string | null;
  pendingParagraphs: Record<string, true>;
}

type Action =
  | { type: "set_index"; entries: CalcIndexEntry[] }
  | { type: "set_calc"; calc: Calc }
  | { type: "set_active"; id: string | null }
  | { type: "patch_paragraph"; calcId: string; paragraphId: string; patch: Partial<CalcParagraph> }
  | { type: "set_translating"; calcId: string; paragraphId: string; translating: boolean }
  | { type: "remove_calc"; id: string };

function reducer(state: State, action: Action): State {
  switch (action.type) {
    case "set_index": return { ...state, index: action.entries };
    case "set_calc":  return { ...state, calcs: { ...state.calcs, [action.calc.id]: action.calc } };
    case "set_active": return { ...state, activeId: action.id };
    case "patch_paragraph": {
      const calc = state.calcs[action.calcId];
      if (!calc) return state;
      return {
        ...state,
        calcs: {
          ...state.calcs,
          [action.calcId]: {
            ...calc,
            paragraphs: (() => {
              const idx = calc.paragraphs.findIndex(p => p.id === action.paragraphId);
              if (idx >= 0) {
                return calc.paragraphs.map(p =>
                  p.id === action.paragraphId ? { ...p, ...action.patch } : p);
              }
              // Server-created paragraph the client hasn't seen yet — append it.
              const seed: CalcParagraph = {
                id: action.paragraphId,
                text: "",
                code_template: "",
                parameters: [],
                last_value_short: null,
                last_value_long: null,
                last_error: null,
              };
              return [...calc.paragraphs, { ...seed, ...action.patch }];
            })(),
          },
        },
      };
    }
    case "set_translating": {
      const key = `${action.calcId}:${action.paragraphId}`;
      const next = { ...state.pendingParagraphs };
      if (action.translating) next[key] = true;
      else delete next[key];
      return { ...state, pendingParagraphs: next };
    }
    case "remove_calc": {
      const { [action.id]: _, ...rest } = state.calcs;
      return {
        ...state,
        calcs: rest,
        index: state.index.filter(e => e.id !== action.id),
        activeId: state.activeId === action.id ? null : state.activeId,
      };
    }
  }
}

interface Ctx {
  state: State;
  listCalcs: () => Promise<void>;
  loadCalc: (id: string) => Promise<void>;
  createCalc: (name: string) => Promise<Calc>;
  deleteCalc: (id: string) => Promise<void>;
  renameCalc: (id: string, name: string) => Promise<void>;
  setActive: (id: string | null) => void;
  updateParagraph: (calcId: string, paragraphId: string, text: string) => Promise<void>;
  evalParagraph: (calcId: string, paragraphId: string) => Promise<void>;
  isTranslating: (calcId: string, paragraphId: string) => boolean;
}

const CalcsContext = createContext<Ctx | null>(null);

export function CalcsProvider({ children }: { children: ReactNode }) {
  const { call, send, onEvent } = useSidecar();
  const [state, dispatch] = useReducer(reducer, {
    index: [], calcs: {}, activeId: null, pendingParagraphs: {},
  });

  useEffect(() => {
    return onEvent((ev: SidecarEvent) => {
      if (ev.type === "calcs") dispatch({ type: "set_index", entries: ev.calcs });
      else if (ev.type === "calc") dispatch({ type: "set_calc", calc: ev.calc });
      else if (ev.type === "calc_paragraph_result") {
        dispatch({
          type: "patch_paragraph",
          calcId: ev.calc_id,
          paragraphId: ev.paragraph_id,
          patch: {
            code_template: ev.code_template,
            parameters: ev.parameters,
            last_value_short: ev.value_short,
            last_value_long: ev.value_long,
            last_error: null,
          },
        });
        dispatch({ type: "set_translating", calcId: ev.calc_id, paragraphId: ev.paragraph_id, translating: false });
      }
      else if (ev.type === "calc_paragraph_error") {
        dispatch({
          type: "patch_paragraph",
          calcId: ev.calc_id,
          paragraphId: ev.paragraph_id,
          patch: { last_error: ev.error, last_value_short: "error", last_value_long: null },
        });
        dispatch({ type: "set_translating", calcId: ev.calc_id, paragraphId: ev.paragraph_id, translating: false });
      }
      else if (ev.type === "calc_translating") {
        dispatch({ type: "set_translating", calcId: ev.calc_id, paragraphId: ev.paragraph_id, translating: true });
      }
    });
  }, [onEvent]);

  const listCalcs = useCallback(async () => {
    const reply = await call({ type: "calcs_list" });
    if (reply?.calcs) dispatch({ type: "set_index", entries: reply.calcs });
  }, [call]);

  const loadCalc = useCallback(async (id: string) => {
    const reply = await call({ type: "calc_get", calc_id: id });
    if (reply?.calc) dispatch({ type: "set_calc", calc: reply.calc });
  }, [call]);

  const createCalc = useCallback(async (name: string): Promise<Calc> => {
    const reply = await call({ type: "calc_create", name });
    dispatch({ type: "set_calc", calc: reply.calc });
    await listCalcs();
    return reply.calc;
  }, [call, listCalcs]);

  const deleteCalc = useCallback(async (id: string) => {
    await call({ type: "calc_delete", calc_id: id });
    dispatch({ type: "remove_calc", id });
  }, [call]);

  const renameCalc = useCallback(async (id: string, name: string) => {
    await call({ type: "calc_rename", calc_id: id, name });
    await listCalcs();
  }, [call, listCalcs]);

  const setActive = useCallback((id: string | null) => {
    dispatch({ type: "set_active", id });
    if (id && !state.calcs[id]) loadCalc(id);
  }, [loadCalc, state.calcs]);

  const updateParagraph = useCallback(async (calcId: string, paragraphId: string, text: string) => {
    dispatch({ type: "patch_paragraph", calcId, paragraphId, patch: { text } });
    await send({ type: "calc_update_paragraph", calc_id: calcId, paragraph_id: paragraphId, text });
  }, [send]);

  const evalParagraph = useCallback(async (calcId: string, paragraphId: string) => {
    await send({ type: "calc_eval_paragraph", calc_id: calcId, paragraph_id: paragraphId });
  }, [send]);

  const isTranslating = useCallback((calcId: string, paragraphId: string) =>
    !!state.pendingParagraphs[`${calcId}:${paragraphId}`], [state.pendingParagraphs]);

  useEffect(() => { listCalcs(); }, [listCalcs]);

  const value = useMemo<Ctx>(() => ({
    state, listCalcs, loadCalc, createCalc, deleteCalc, renameCalc,
    setActive, updateParagraph, evalParagraph, isTranslating,
  }), [state, listCalcs, loadCalc, createCalc, deleteCalc, renameCalc,
       setActive, updateParagraph, evalParagraph, isTranslating]);

  return <CalcsContext.Provider value={value}>{children}</CalcsContext.Provider>;
}

export function useCalcs() {
  const ctx = useContext(CalcsContext);
  if (!ctx) throw new Error("useCalcs must be inside <CalcsProvider>");
  return ctx;
}
