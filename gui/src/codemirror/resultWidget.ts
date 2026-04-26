import { Extension, StateField, StateEffect, Range } from "@codemirror/state";
import { EditorView, Decoration, DecorationSet, WidgetType } from "@codemirror/view";
import { createRoot, Root } from "react-dom/client";
import { createElement } from "react";
import type { CalcParagraph } from "@/types/sidecar";
import ResultWidget from "@/components/calcs/ResultWidget";
import { getParagraphs } from "./paragraphTracker";

interface WidgetState {
  metaByParaId: Map<string, CalcParagraph>;
  translatingByParaId: Set<string>;
}

export const setResultWidgetState = StateEffect.define<WidgetState>();

const widgetStateField = StateField.define<WidgetState>({
  create() { return { metaByParaId: new Map(), translatingByParaId: new Set() }; },
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setResultWidgetState)) return e.value;
    return value;
  },
});

class ResultBlockWidget extends WidgetType {
  private root: Root | null = null;
  constructor(
    private paraId: string,
    private meta: CalcParagraph | null,
    private translating: boolean,
  ) { super(); }

  eq(other: ResultBlockWidget) {
    return other.paraId === this.paraId &&
           other.translating === this.translating &&
           JSON.stringify(other.meta) === JSON.stringify(this.meta);
  }

  toDOM() {
    const wrap = document.createElement("span");
    wrap.className = "cm-calc-result-widget";
    if (!this.meta) return wrap;
    const renderedCode = renderCodeTemplate(this.meta);
    this.root = createRoot(wrap);
    this.root.render(createElement(ResultWidget, {
      paragraph: this.meta, renderedCode, translating: this.translating,
    }));
    return wrap;
  }

  destroy(_dom: HTMLElement) {
    if (this.root) {
      const r = this.root;
      this.root = null;
      setTimeout(() => r.unmount(), 0);
    }
  }
}

function renderCodeTemplate(meta: CalcParagraph): string {
  return meta.code_template.replace(/\{\{([a-zA-Z0-9_]+)\}\}/g, (_, id) => {
    const p = meta.parameters.find(x => x.id === id);
    return p ? p.current_value : `{{${id}}}`;
  });
}

const widgetDecorations = StateField.define<DecorationSet>({
  create() { return Decoration.none; },
  update(_, tr) {
    const ws = tr.state.field(widgetStateField, false);
    if (!ws) return Decoration.none;
    const paragraphs = getParagraphs(tr.state);
    const decos: Range<Decoration>[] = [];
    for (const p of paragraphs) {
      const meta = ws.metaByParaId.get(p.id) ?? null;
      const translating = ws.translatingByParaId.has(p.id);
      const widget = Decoration.widget({
        widget: new ResultBlockWidget(p.id, meta, translating),
        side: 1,
      });
      decos.push(widget.range(p.to));
    }
    return Decoration.set(decos, true);
  },
  provide: f => EditorView.decorations.from(f),
});

export function resultWidgetExtension(): Extension {
  return [widgetStateField, widgetDecorations];
}
