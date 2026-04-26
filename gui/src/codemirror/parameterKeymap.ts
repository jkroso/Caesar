import { Extension } from "@codemirror/state";
import { keymap, EditorView } from "@codemirror/view";
import { byteToChar, paramMap } from "./parameterDecoration";
import { getParagraphs, flushPendingEdits } from "./paragraphTracker";

export function parameterKeymap(): Extension {
  return keymap.of([
    { key: "Mod-ArrowUp", preventDefault: true, run: v => stepParam(v, +1) },
    { key: "Mod-ArrowDown", preventDefault: true, run: v => stepParam(v, -1) },
  ]);
}

function stepParam(view: EditorView, dir: 1 | -1): boolean {
  const state = view.state;
  const cursor = state.selection.main.head;
  const paragraph = getParagraphs(state).find(p => cursor >= p.from && cursor <= p.to);
  if (!paragraph) return false;
  const map = state.field(paramMap, false);
  const meta = map?.get(paragraph.id);
  if (!meta) return false;

  for (const param of meta.parameters) {
    const [bStart, bEnd] = param.text_span;
    const cStart = byteToChar(paragraph.text, bStart);
    const cEnd = byteToChar(paragraph.text, bEnd);
    const from = paragraph.from + cStart;
    const to = paragraph.from + cEnd;
    if (cursor < from || cursor > to) continue;

    const text = state.doc.sliceString(from, to);
    const next = transform(text, dir);
    if (next == null) return false;

    view.dispatch({
      changes: { from, to, insert: next },
      selection: { anchor: from + next.length },
    });
    flushPendingEdits();
    return true;
  }
  return false;
}

function transform(s: string, dir: 1 | -1): string | null {
  if (s === "true") return "false";
  if (s === "false") return "true";
  const m = s.match(/-?\d+(?:\.\d+)?/);
  if (!m) return null;
  const stepped = stepNumberString(m[0], dir);
  if (stepped == null) return null;
  return s.slice(0, m.index!) + stepped + s.slice(m.index! + m[0].length);
}

function stepNumberString(s: string, dir: 1 | -1): string | null {
  const m = s.match(/^(-?)(\d+)(?:\.(\d+))?$/);
  if (!m) return null;
  const sign = m[1] === "-" ? -1 : 1;
  const intPart = m[2];
  const fracPart = m[3] ?? "";
  const decimals = fracPart.length;
  const combined = parseInt(intPart + fracPart, 10);
  if (!Number.isFinite(combined)) return null;
  const next = sign * combined + dir;
  const absNext = Math.abs(next);
  let str = absNext.toString();
  if (decimals > 0) str = str.padStart(decimals + 1, "0");
  const intOut = decimals > 0 ? str.slice(0, str.length - decimals) : str;
  const fracOut = decimals > 0 ? str.slice(str.length - decimals) : "";
  const signOut = next < 0 ? "-" : "";
  return signOut + intOut + (decimals > 0 ? "." + fracOut : "");
}
