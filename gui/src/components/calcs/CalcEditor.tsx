import { useEffect, useRef } from "react";
import { EditorState } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { useCalcs } from "@/contexts/CalcsContext";
import type { Calc, CalcParagraph } from "@/types/sidecar";
import { paragraphTracker, getParagraphs, flushPendingEdits } from "@/codemirror/paragraphTracker";
import type { ParagraphRange } from "@/codemirror/paragraphTracker";
import { parameterDecoration, setParameterMap } from "@/codemirror/parameterDecoration";
import { resultWidgetExtension, setResultWidgetState } from "@/codemirror/resultWidget";

const calcsTheme = EditorView.theme({
  "&": {
    backgroundColor: "transparent",
    color: "var(--color-text)",
    fontSize: "15px",
    height: "100%",
  },
  ".cm-content": {
    caretColor: "var(--color-accent, #5a8de8)",
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
    padding: "16px 0",
  },
  "&.cm-focused .cm-cursor": {
    borderLeftColor: "var(--color-accent, #5a8de8)",
    borderLeftWidth: "2px",
  },
  ".cm-line": {
    padding: "0 4px",
    lineHeight: "1.6",
  },
  "&.cm-focused": { outline: "none" },
  ".cm-selectionBackground, ::selection": {
    backgroundColor: "var(--color-accent-soft, rgba(90,141,232,0.25))",
  },
  ".cm-scroller": { fontFamily: "inherit" },
}, { dark: true });

function newClientParagraphId() {
  return "para_" + Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);
}

interface Props {
  calc: Calc;
}

export default function CalcEditor({ calc }: Props) {
  const { state, updateParagraph, evalParagraph, isTranslating } = useCalcs();
  const elRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<EditorView | null>(null);
  const idMapRef = useRef<Map<string, string>>(new Map());

  // Mount editor once per calc id
  useEffect(() => {
    if (!elRef.current) return;

    const initialDoc = calc.paragraphs.map(p => p.text).join("\n\n");

    const view = new EditorView({
      parent: elRef.current,
      state: EditorState.create({
        doc: initialDoc,
        extensions: [
          history(),
          // Bind Mod-Enter BEFORE defaultKeymap so our handler wins over any
          // default Enter behavior, and `preventDefault: true` stops the
          // browser from also inserting a newline character.
          keymap.of([
            { key: "Mod-Enter", preventDefault: true,
              run: () => { flushPendingEdits(); triggerEvalAtCursor(); return true; } },
            ...defaultKeymap,
            ...historyKeymap,
          ]),
          markdown(),
          calcsTheme,
          paragraphTracker({
            onChange: (changes) => {
              const v = viewRef.current!;
              const paras = getParagraphs(v.state);
              for (const change of changes) {
                if (change.type === "deleted") {
                  idMapRef.current.delete(change.paragraph.id);
                } else {
                  associateByIndex(calc, idMapRef.current, paras);
                  let serverId = idMapRef.current.get(change.paragraph.id);
                  if (!serverId) {
                    // New paragraph: mint a client-side id; server will create-on-missing.
                    serverId = newClientParagraphId();
                    idMapRef.current.set(change.paragraph.id, serverId);
                  }
                  updateParagraph(calc.id, serverId, change.paragraph.text);
                }
              }
            },
          }),
          parameterDecoration(),
          resultWidgetExtension(),
        ],
      }),
    });
    viewRef.current = view;

    associateByIndex(calc, idMapRef.current, getParagraphs(view.state));
    pushMetadata(view, calc, idMapRef.current, isTranslating);

    function triggerEvalAtCursor() {
      const cursor = view.state.selection.main.head;
      const paras = getParagraphs(view.state);
      const cm = paras.find(p => cursor >= p.from && cursor <= p.to);
      if (!cm) return;
      const serverId = idMapRef.current.get(cm.id);
      if (serverId) evalParagraph(calc.id, serverId);
    }

    return () => view.destroy();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [calc.id]);

  // Push metadata whenever calc or translating state changes.
  useEffect(() => {
    if (!viewRef.current) return;
    pushMetadata(viewRef.current, calc, idMapRef.current, isTranslating);
  }, [calc, isTranslating, state.pendingParagraphs]);

  return <div ref={elRef} className="h-full overflow-auto p-6 calc-editor" />;
}

function associateByIndex(
  calc: Calc,
  idMap: Map<string, string>,
  cmParas: ParagraphRange[],
) {
  for (let i = 0; i < cmParas.length; i++) {
    const cm = cmParas[i];
    const server = calc.paragraphs[i];
    if (server) idMap.set(cm.id, server.id);
  }
}

function pushMetadata(
  view: EditorView,
  calc: Calc,
  idMap: Map<string, string>,
  isTranslating: (calcId: string, paragraphId: string) => boolean,
) {
  const paras = getParagraphs(view.state);
  const meta = new Map<string, CalcParagraph>();
  const translating = new Set<string>();
  for (const cm of paras) {
    const serverId = idMap.get(cm.id);
    if (!serverId) continue;
    const server = calc.paragraphs.find(p => p.id === serverId);
    if (server) {
      meta.set(cm.id, server);
      if (isTranslating(calc.id, server.id)) translating.add(cm.id);
    }
  }
  view.dispatch({
    effects: [
      setParameterMap.of(meta),
      setResultWidgetState.of({ metaByParaId: meta, translatingByParaId: translating }),
    ],
  });
}
