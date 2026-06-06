# Restore Full Functionality — Increment Roadmap

Rebuilding the prior Lume feature set on the native (Xcode app + TextKit 2) foundation.
The old domain logic was UI-free and is ported as-is into `LumeKit`; the UI is rebuilt
natively (no CodeMirror/WebView).

## Increment 1 — Foundation ✅ (this branch)
Ported into `LumeKit` (one module, was 5 frameworks):
- ConfigKit (ConfigValue, EnvFile, JSON/YAML/TOML/Plist formats, ConfigRegistry)
- DocumentKit (Breadcrumb, DisplayName, DocumentRouter, GroupSort, PathExport)
- FileSystemKit (FileKind, FileNode, FileService, FileSystemCache, DirectoryWatcher, FileOps, VisibleChildrenFilter)
- LibraryKit (SwiftData Models: Favorite/Tag/FileMeta/Bookmark; LibraryStore, TagPalette, TagSuggest)
- SelectionKit (RowSelection, GroupRowID, GroupRowOrder, GroupSelection)
- Deps: Yams, TOMLKit. Adopted richer FileKind/FileNode (replaced v1 stubs).
- 95 tests passing.

## Increment 2 — Document viewers (native)
`DocumentRouter`-driven detail pane. Native viewers:
- Markdown: existing TextKit 2 editor (keep)
- Code: TextKit 2 read-only/editable + basic highlight
- `.env`: native masked key=value editor (mask/reveal)
- Config (JSON/YAML/TOML/plist): structured SwiftUI form + raw toggle (ConfigKit)
- PDF: PDFKit; Image: native NSImageView (downsample); HTML: WKWebView (content-only)
- QuickLook: QLPreviewView fallback
- SwiftData model container wired into the app.

## Increment 3 — Sidebar (3 regions)
GROUPS / Favorites / Open Folder. Pinning, drill-in/up, breadcrumb (hold-⌃),
FSEvents auto-refresh (FileSystemCache + DirectoryWatcher), hidden toggles, files-only,
name filter (VisibleChildrenFilter).

## Increment 4 — Tags & GROUPS
Document tag header + add popover, GROUPS virtual-folder navigator, drag-to-tag,
New Group, tag manager (rename/merge/recolor/delete), colorful tags (TagPalette).

## Increment 5 — Multi-select & file ops
Multi-select (SelectionKit), action bar, Copy Paths (⌥⌘C), file CRUD + Undo
(new folder/rename/trash/duplicate/reveal), hide/peek, display names.

## Increment 6 — Polish
Full keyboard shortcuts, menu commands (LumeCommands), accessibility,
light/dark tuning, iCloud-aware reads (NSFileCoordinator).

Each increment: build + tests + launch-verify before merge.
