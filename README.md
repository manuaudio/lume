# Lume

**A fast, native macOS workspace for your Markdown, notes, code, and config files.**

Point Lume at any folder and get a responsive, Finder-like sidebar plus a native
editor — built entirely in Swift 6 + SwiftUI + AppKit as a real `.app`. No Electron,
no web wrapper, no JavaScript editor. It opens files in milliseconds and takes your
clicks the instant the window appears.

> **Platform:** macOS 14 (Sonoma) or later · Apple Silicon & Intel
> **Status:** early rebuild — the *responsive core* is in place (see Roadmap).

---

## What works today

- **📂 Open any folder as a workspace** — choose a directory (⌘O) and browse it in a
  native sidebar. Directories expand lazily, so opening a large tree never stalls.
- **✍️ Native TextKit 2 editor** — open, edit, and save text files. Markdown gets
  lightweight live highlighting (headings, **bold**, _emphasis_, `code`, links). A
  selected file opens focused and ready to type.
- **💾 Save & find** — ⌘S saves (atomically, off the main thread); the editor provides
  native Find (⌘F) and Undo (⌘Z).
- **🧭 Stays out of your way** — non-text files offer "Open in Default App"; your last
  folder and window position are restored on relaunch.
- **⚡ Snappy by construction** — file reads happen off the main thread and the editor
  is fully native, so the UI never blocks on disk or rendering.

## Architecture

| Module    | Responsibility                                                              |
|-----------|-----------------------------------------------------------------------------|
| `LumeKit` | UI-free, unit-tested domain logic: folder scanning, file classification, document load/save, markdown tokenizing. |
| `Lume`    | Thin SwiftUI/AppKit shell: window, sidebar, TextKit 2 editor, view-model.   |

The project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen)
into a standard Xcode app target — which is what gives Lume normal macOS window
activation and event handling out of the box.

## Build & run

```sh
brew install xcodegen          # one-time
xcodegen generate              # project.yml -> Lume.xcodeproj
xcodebuild -project Lume.xcodeproj -scheme Lume -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Lume.app
```

Run the tests:

```sh
xcodebuild test -project Lume.xcodeproj -scheme Lume -destination 'platform=macOS' -derivedDataPath build
```

## Roadmap

Lume is being rebuilt from a clean native foundation. Planned increments, each
returning a feature set the earlier prototype had:

- Tags + **GROUPS** (tags as virtual folders), pinning, display names, colorful tags
- Dedicated viewers: PDF, image, source code, `.env`, YAML/TOML/JSON config, HTML
- File management (create / rename / move / delete) with Undo, drag-to-tag / drag-to-pin
- **SSH remote editing** *(shipped)* — connect to a host from the sidebar source
  switcher, browse, and atomically edit remote text/config files
- **GitHub repo editing** *(shipped)* — see below

### GitHub repos

Open any GitHub repository from the source switcher (`owner/repo`, a pasted
URL, or the Browse Your Repos picker — requires the [gh CLI](https://cli.github.com)
signed in via `gh auth login`). Browse the repo tree, pick a branch, and edit
text/config files with Lume's editors; ⌘S commits directly to the active
branch ("Update <path>"). If the file changed on GitHub since you opened it,
the save is rejected and Lume offers to reload — your edits are never silently
lost, and neither are anyone else's.

### One Favorites list for every source

Pin local files, SSH paths, and GitHub repo files into a single Favorites
list. Remote favorites carry a small source badge (⚡ host for SSH, branch icon
+ repo for GitHub); clicking one connects to its source if needed and opens the
file — or reroots the tree, for a pinned folder. Right-click any remote tree
row to Add/Remove from Favorites. Favorites persist locally (no server sync).
- App Sandbox + signed distribution

## License

MIT — see [LICENSE](LICENSE).
