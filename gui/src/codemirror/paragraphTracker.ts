import { Extension, StateField, EditorState } from "@codemirror/state";
import { EditorView, ViewPlugin, ViewUpdate } from "@codemirror/view";

export interface ParagraphRange {
  id: string;
  from: number;
  to: number;
  text: string;
}

export interface ParagraphChange {
  type: "created" | "deleted" | "edited";
  paragraph: ParagraphRange;
  oldParagraph?: ParagraphRange;
}

let _paraSeq = 0;
function nextParaId() { return `cm_${++_paraSeq}_${Date.now().toString(36)}`; }

export function computeParagraphs(doc: string, prior: ParagraphRange[]): ParagraphRange[] {
  const out: ParagraphRange[] = [];
  if (doc.length === 0) return out;
  const matches: { start: number; end: number; text: string }[] = [];
  let i = 0;
  while (i < doc.length) {
    while (i < doc.length && doc[i] === "\n") i++;
    if (i >= doc.length) break;
    const start = i;
    while (i < doc.length) {
      if (doc[i] === "\n" && doc[i + 1] === "\n") break;
      i++;
    }
    let end = i;
    while (end > start && (doc[end - 1] === "\n" || doc[end - 1] === " " || doc[end - 1] === "\t")) end--;
    if (end > start) matches.push({ start, end, text: doc.slice(start, end) });
    while (i < doc.length && doc[i] === "\n") i++;
  }

  // Reuse ids by ordinal index. When text differs at the same index,
  // that's an "edited" event. New paragraphs at the end get fresh ids.
  // (More sophisticated diff-based matching deferred until the simple
  // model causes problems with mid-document insertions.)
  for (let k = 0; k < matches.length; k++) {
    const m = matches[k];
    const id = prior[k] ? prior[k].id : nextParaId();
    out.push({ id, from: m.start, to: m.end, text: m.text });
  }
  return out;
}

const paragraphsField = StateField.define<ParagraphRange[]>({
  create(state) { return computeParagraphs(state.doc.toString(), []); },
  update(value, tr) {
    if (!tr.docChanged) return value;
    return computeParagraphs(tr.state.doc.toString(), value);
  },
});

export function getParagraphs(state: EditorState): ParagraphRange[] {
  return state.field(paragraphsField);
}

export interface ParagraphTrackerOptions {
  onChange: (changes: ParagraphChange[]) => void;
  debounceMs?: number;
}

export function paragraphTracker(opts: ParagraphTrackerOptions): Extension {
  const debounceMs = opts.debounceMs ?? 250;
  const pending = new Map<string, ReturnType<typeof setTimeout>>();

  const plugin = ViewPlugin.fromClass(class {
    prior: ParagraphRange[] = [];

    constructor(view: EditorView) {
      this.prior = getParagraphs(view.state);
    }

    update(u: ViewUpdate) {
      if (!u.docChanged) return;
      const next = getParagraphs(u.state);
      const changes: ParagraphChange[] = [];

      const priorById = new Map(this.prior.map(p => [p.id, p]));
      const nextById = new Map(next.map(p => [p.id, p]));

      for (const p of next) {
        const old = priorById.get(p.id);
        if (!old) changes.push({ type: "created", paragraph: p });
        else if (old.text !== p.text) changes.push({ type: "edited", paragraph: p, oldParagraph: old });
      }
      for (const p of this.prior) {
        if (!nextById.has(p.id)) changes.push({ type: "deleted", paragraph: p });
      }

      this.prior = next;
      if (changes.length === 0) return;

      const immediate = changes.filter(c => c.type !== "edited");
      const editsByPara = changes.filter(c => c.type === "edited");
      if (immediate.length > 0) opts.onChange(immediate);
      for (const c of editsByPara) {
        const id = c.paragraph.id;
        const t = pending.get(id);
        if (t) clearTimeout(t);
        pending.set(id, setTimeout(() => {
          pending.delete(id);
          opts.onChange([c]);
        }, debounceMs));
      }
    }

    destroy() {
      for (const t of pending.values()) clearTimeout(t);
      pending.clear();
    }
  });

  return [paragraphsField, plugin];
}
