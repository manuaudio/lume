import { EditorState, Compartment } from "@codemirror/state";
import { EditorView, keymap, highlightActiveLine } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { syntaxHighlighting, HighlightStyle } from "@codemirror/language";
import { tags } from "@lezer/highlight";
import { markdown } from "@codemirror/lang-markdown";
import { languages } from "@codemirror/language-data";

const editableComp = new Compartment();

// Token classes map to CSS variables in editor.css, so light/dark is driven
// entirely by toggling the `theme-dark` body class — no per-theme JS colors.
const mdHighlight = HighlightStyle.define([
  { tag: tags.heading1, class: "tok-h1" },
  { tag: tags.heading2, class: "tok-h2" },
  { tag: [tags.heading3, tags.heading4, tags.heading5, tags.heading6], class: "tok-h3" },
  { tag: tags.processingInstruction, class: "tok-mark" }, // #, *, -, >, ` markers
  { tag: tags.strong, class: "tok-strong" },
  { tag: tags.emphasis, class: "tok-em" },
  { tag: tags.monospace, class: "tok-code" },
  { tag: tags.link, class: "tok-link" },
  { tag: tags.url, class: "tok-url" },
  { tag: tags.quote, class: "tok-quote" },
  { tag: tags.list, class: "tok-list" },
]);

// Theme reads CSS variables so a body-class toggle restyles everything live.
const baseTheme = EditorView.theme({
  "&": { backgroundColor: "var(--bg)", color: "var(--text)" },
  ".cm-content": { caretColor: "var(--accent)" },
});

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

function applyThemeClass(theme) {
  document.body.classList.toggle("theme-dark", theme === "dark");
}

window.Lume = {
  init({ text = "", mode = "markdown", editable = true, theme = "light" }) {
    applyThemeClass(theme);
    const state = EditorState.create({
      doc: text,
      extensions: [
        history(),
        EditorView.lineWrapping,
        highlightActiveLine(),
        keymap.of([...defaultKeymap, ...historyKeymap]),
        markdown({ codeLanguages: languages }),
        syntaxHighlighting(mdHighlight),
        baseTheme,
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
  setTheme(theme) { applyThemeClass(theme); },
};
