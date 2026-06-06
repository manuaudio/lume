# Lume

**A fast, native macOS workspace for your Markdown, notes, code, and config files.**

Lume turns any folder on your Mac into a browsable, taggable document workspace. Open a directory, get a Finder-like sidebar, and edit Markdown in a clean editor — while PDFs, images, code, `.env`, and structured config files (YAML / TOML / JSON) each open in a viewer built for them. Organize across folders with colorful tags that behave like virtual folders, pin what matters, and hide what doesn't.

Built entirely in Swift 6 + SwiftUI as a native `.app` — no Electron, no web wrapper.

> **Platform:** macOS 14 (Sonoma) or later · Apple Silicon & Intel

---

## Highlights

- **📂 Open any folder as a workspace** — point Lume at a directory and browse it in a responsive, native sidebar with multi-select, Copy Paths, and Finder-style keyboard navigation.
- **✍️ Markdown editor** — a focused CodeMirror-based editor for `.md`, bundled and offline (no network, no telemetry).
- **🗂️ GROUPS — tags as virtual folders** — tag files anywhere in the tree and they appear as expandable groups in the sidebar. Drag to tag, create new groups, and jump across folders instantly.
- **🎨 Colorful tags** — color-indexed, renamable (rename-to-merge), and recolorable, with a quick token field for adding tags inline.
- **📌 Pin & hide** — curate a workspace by pinning the files you live in and hiding the noise, with separate pinned/browser visibility and a hold-⌃ peek at hidden items.
- **🧰 The right viewer for every file** — Markdown, source code, `.env` (structured editor), YAML/TOML/JSON config (structured editor with a raw toggle), PDF, images, HTML, plus a Quick Look fallback for everything else.
- **🏷️ Display names** — give files friendlier names in the UI without renaming them on disk.
- **↩️ File management with Undo** — create, rename, move, and delete files from inside the app, with undo support and drag-to-pin / drag-to-tag.
- **⚡ Built for speed** — native single-click selection (no tap delay), constant-cost sidebar rendering, and off-main-thread file work so the UI stays responsive even in large trees.

---

## Install

Lume ships as a self-contained `.app`. You build it once and it installs to `/Applications`.

### Requirements

- macOS 14+
- [Xcode](https://developer.apple.com/xcode/) (provides the Swift 6 toolchain used by the build)

### Build & install

```bash
git clone https://github.com/manuaudio/lume.git
cd lume
./tools/build-app.sh --run
```

That script does a release build, assembles `dist/Lume.app` with its icon, installs a copy to `/Applications` (or `~/Applications` if that isn't writable), registers it with Launchpad/Spotlight, and — with `--run` — launches it.

After the first build you can open Lume from Launchpad, Spotlight, or your Applications folder like any other app.

> **Note:** `build-app.sh` is the only supported way to run Lume as a real app. The bare `swift build` binary has no bundle identity, icon, or resource bundle and will trap at launch.

If Xcode isn't at the default path, point the build at your toolchain:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./tools/build-app.sh --run
```

---

## Usage

1. Launch Lume and choose **Open Folder** (or use the empty-state button).
2. Browse the folder in the sidebar; click a file to open it in the center pane.
3. Select one or more files and add tags — they'll show up under **GROUPS** as virtual folders you can expand and navigate.
4. **Pin** the files you want at the top; **hide** the ones you don't. Hold **⌃** to peek at hidden items.
5. Edit Markdown directly; PDFs, images, code, and config files open in their dedicated viewers.

Your tags, pins, display names, and favorites are stored locally via SwiftData and persist across launches.

---

## Architecture

Lume is a Swift Package built from small, app-agnostic frameworks behind a thin SwiftUI app target:

| Module | Responsibility |
| --- | --- |
| `FileSystemKit` | Filesystem traversal, file nodes, visibility filtering |
| `LibraryKit` | Tags, groups, pins, display names, the document library model |
| `DocumentKit` | File-kind routing and document concerns |
| `ConfigKit` | Structured config parsing/editing (YAML via [Yams](https://github.com/jpsim/Yams), TOML via [TOMLKit](https://github.com/LebJe/TOMLKit)) |
| `SelectionKit` | Multi-selection model and revalidation |
| `LumeUI` | Reusable SwiftUI components (tag chips, tag field, flow layout) |
| `LumeCore` | Umbrella facade re-exporting the kits |
| `LumeApp` | The macOS app: sidebar, document surfaces, commands, services |

The Markdown editor lives in [`web/`](web/) (a small CodeMirror 6 bundle, built with esbuild). Its compiled output is committed under `Sources/LumeApp/Resources/web/`, so a normal app build needs no Node toolchain. To rebuild the editor:

```bash
cd web
npm install
node build.mjs   # writes dist/editor.bundle.js
```

---

## Development

Run the test suite (146+ unit tests across the kits):

```bash
swift test
```

Build a debug binary for quick iteration (UI experiments only — use `build-app.sh` for the real app):

```bash
swift build
```

Optional sandboxed build (opt-in; see the notes in `tools/build-app.sh`):

```bash
./tools/build-app.sh --sandbox
```

---

## License

[MIT](LICENSE) © manuaudio
