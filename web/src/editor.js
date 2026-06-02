import { EditorState, Compartment } from "@codemirror/state";
import { EditorView, keymap, highlightActiveLine } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import {
  syntaxHighlighting, defaultHighlightStyle, HighlightStyle,
} from "@codemirror/language";
import { tags } from "@lezer/highlight";
import { markdown } from "@codemirror/lang-markdown";
import { languages } from "@codemirror/language-data";
import { oneDark } from "@codemirror/theme-one-dark";

const editableComp = new Compartment();
const langComp = new Compartment();
const themeComp = new Compartment();

// MarkEdit-style: size headings, style emphasis. Classes map to editor.css.
const mdHighlight = HighlightStyle.define([
  { tag: tags.heading1, class: "tok-heading1" },
  { tag: tags.heading2, class: "tok-heading2" },
  { tag: tags.heading3, class: "tok-heading3" },
  { tag: tags.strong, fontWeight: "700" },
  { tag: tags.emphasis, fontStyle: "italic" },
  { tag: tags.monospace, color: "#0a7" },
]);

let view;

function post(type, payload) {
  if (window.webkit?.messageHandlers?.lume) {
    window.webkit.messageHandlers.lume.postMessage({ type, ...payload });
  }
}

// Debounce disk writes (~400ms) so we don't hammer the file on every keystroke.
let changeTimer = null;
let pendingText = null;
function flushChange() {
  changeTimer = null;
  if (pendingText !== null) {
    post("change", { text: pendingText });
    pendingText = null;
  }
}
const changeListener = EditorView.updateListener.of((u) => {
  if (!u.docChanged) return;
  pendingText = u.state.doc.toString();
  if (changeTimer !== null) clearTimeout(changeTimer);
  changeTimer = setTimeout(flushChange, 400);
});

window.Lume = {
  init({ text = "", mode = "markdown", editable = true, theme = "light" }) {
    const langExt = mode === "markdown"
      ? markdown({ codeLanguages: languages })
      : markdown({ codeLanguages: languages }); // both modes use markdown grammar for v1; code files still readable
    const state = EditorState.create({
      doc: text,
      extensions: [
        history(),
        highlightActiveLine(),
        keymap.of([...defaultKeymap, ...historyKeymap]),
        syntaxHighlighting(defaultHighlightStyle),
        syntaxHighlighting(mdHighlight),
        langComp.of(langExt),
        themeComp.of(theme === "dark" ? oneDark : []),
        editableComp.of(EditorView.editable.of(editable)),
        changeListener,
      ],
    });
    // Cancel any pending debounced write from a previous document.
    if (changeTimer !== null) { clearTimeout(changeTimer); changeTimer = null; }
    pendingText = null;
    if (view) view.destroy();
    view = new EditorView({ state, parent: document.getElementById("editor") });
    post("ready", {});
  },
  setContent(text) {
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
  },
  getContent() { return view ? view.state.doc.toString() : ""; },
  setEditable(editable) {
    view.dispatch({ effects: editableComp.reconfigure(EditorView.editable.of(editable)) });
  },
  setTheme(theme) {
    view.dispatch({ effects: themeComp.reconfigure(theme === "dark" ? oneDark : []) });
    document.body.style.setProperty("--lume-bg", theme === "dark" ? "#1e1e1e" : "#ffffff");
  },
};
