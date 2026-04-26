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
  // A paragraph is a single non-empty line. Splits on every newline.
  // The range extends to end-of-line (including trailing whitespace) so
  // typing a trailing space doesn't push the cursor "out" of the paragraph
  // and trigger a premature flush. The reported `text` is still trimmed.
  const matches: { start: number; end: number; text: string }[] = [];
  let i = 0;
  while (i < doc.length) {
    if (doc[i] === "\n") { i++; continue; }
    const start = i;
    while (i < doc.length && doc[i] !== "\n") i++;
    const lineEnd = i;
    let textEnd = lineEnd;
    while (textEnd > start && (doc[textEnd - 1] === " " || doc[textEnd - 1] === "\t")) textEnd--;
    if (textEnd > start) matches.push({ start, end: lineEnd, text: doc.slice(start, textEnd) });
  }

  // Reuse ids by ordinal index. New paragraphs at the end get fresh ids.
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

function paragraphAtPos(paras: ParagraphRange[], pos: number): ParagraphRange | null {
  return paras.find(p => pos >= p.from && pos <= p.to) ?? null;
}

export interface ParagraphTrackerOptions {
  /** Called when a paragraph's edits should be flushed to the backend. */
  onChange: (changes: ParagraphChange[]) => void;
}

/**
 * Tracks paragraph ranges and ids; calls `onChange` only when the user
 * has finished editing a paragraph — i.e., when the cursor moves out of
 * the paragraph or the editor loses focus. Continuous typing within a
 * paragraph never fires; only the boundary event does. Cmd+Enter (handled
 * by the host's keymap) can call `flushAll` directly to force a flush.
 */
export function paragraphTracker(opts: ParagraphTrackerOptions): Extension {
  // Paragraphs whose text differs from what we last reported via onChange.
  const dirty = new Map<string, ParagraphRange>();
  let currentParaId: string | null = null;

  function flush(id: string) {
    const para = dirty.get(id);
    if (!para) return;
    dirty.delete(id);
    opts.onChange([{ type: "edited", paragraph: para }]);
  }

  function flushAll() {
    for (const id of [...dirty.keys()]) flush(id);
  }

  const plugin = ViewPlugin.fromClass(class {
    prior: ParagraphRange[] = [];

    constructor(view: EditorView) {
      this.prior = getParagraphs(view.state);
      currentParaId = paragraphAtPos(this.prior, view.state.selection.main.head)?.id ?? null;
    }

    update(u: ViewUpdate) {
      const next = getParagraphs(u.state);
      const priorById = new Map(this.prior.map(p => [p.id, p]));
      const nextById = new Map(next.map(p => [p.id, p]));

      // Track edits and creations: mark paragraph as dirty.
      // Surface deletions immediately so callers can clean up.
      const immediate: ParagraphChange[] = [];
      for (const p of next) {
        const old = priorById.get(p.id);
        if (!old) {
          // New paragraph — mark dirty; flush on blur or paragraph-leave.
          dirty.set(p.id, p);
        } else if (old.text !== p.text) {
          dirty.set(p.id, p);
        } else if (dirty.has(p.id)) {
          // Range may have shifted (preceding paragraph edit); refresh ref.
          dirty.set(p.id, p);
        }
      }
      for (const p of this.prior) {
        if (!nextById.has(p.id)) {
          immediate.push({ type: "deleted", paragraph: p });
          dirty.delete(p.id);
        }
      }

      this.prior = next;
      if (immediate.length > 0) opts.onChange(immediate);

      // Detect cursor-leaves-paragraph → flush the just-vacated paragraph.
      if (u.selectionSet || u.docChanged) {
        const newParaId = paragraphAtPos(next, u.state.selection.main.head)?.id ?? null;
        if (newParaId !== currentParaId) {
          if (currentParaId !== null) flush(currentParaId);
          currentParaId = newParaId;
        }
      }
    }

    destroy() {}
  });

  // On editor blur, flush every dirty paragraph.
  const blurHandler = EditorView.domEventHandlers({
    blur(_e, _view) {
      flushAll();
      return false;
    },
  });

  // Expose flushAll via a globally-fetchable handle so the host (CalcEditor)
  // can call it from a Cmd+Enter binding.
  (paragraphTracker as any)._lastFlushAll = flushAll;
  return [paragraphsField, plugin, blurHandler];
}

/** Force-flush all pending paragraph edits from the most recently created tracker. */
export function flushPendingEdits() {
  const fn = (paragraphTracker as any)._lastFlushAll;
  if (typeof fn === "function") fn();
}
