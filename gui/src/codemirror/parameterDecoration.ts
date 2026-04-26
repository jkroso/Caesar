import { Extension, StateField, StateEffect, RangeSetBuilder } from "@codemirror/state";
import { EditorView, Decoration, DecorationSet } from "@codemirror/view";
import type { CalcParagraph } from "@/types/sidecar";
import { getParagraphs } from "./paragraphTracker";

export const setParameterMap = StateEffect.define<Map<string, CalcParagraph>>();

export const paramMap = StateField.define<Map<string, CalcParagraph>>({
  create() { return new Map(); },
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setParameterMap)) return e.value;
    return value;
  },
});

const paramMark = Decoration.mark({ class: "cm-calc-parameter" });

const paramDecorations = StateField.define<DecorationSet>({
  create() { return Decoration.none; },
  update(_, tr) {
    const map = tr.state.field(paramMap, false);
    if (!map) return Decoration.none;
    const paragraphs = getParagraphs(tr.state);
    const builder = new RangeSetBuilder<Decoration>();
    for (const p of paragraphs) {
      const meta = map.get(p.id);
      if (!meta) continue;
      for (const param of meta.parameters) {
        const [bStart, bEnd] = param.text_span;
        const cStart = byteToChar(p.text, bStart);
        const cEnd = byteToChar(p.text, bEnd);
        const from = p.from + cStart;
        const to = p.from + cEnd;
        if (from < to) builder.add(from, to, paramMark);
      }
    }
    return builder.finish();
  },
  provide: f => EditorView.decorations.from(f),
});

export function byteToChar(s: string, byteIdx: number): number {
  let bytes = 0;
  for (let i = 0; i < s.length; i++) {
    if (bytes >= byteIdx) return i;
    const code = s.codePointAt(i)!;
    bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
    if (code >= 0x10000) i++;
  }
  return s.length;
}

export function parameterDecoration(): Extension {
  return [paramMap, paramDecorations];
}
