# Phase B — Finder-Feel Sidebar Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Lume sidebar feel like Finder. Stop the custom single/double-click gestures from breaking the List's native ⌘/⇧ multi-select; keep Finder-style disclosure triangles; add keyboard navigation (⇧↑/⇧↓ range extend, ⏎ open/drill, ⌘A select all) on top of the existing Space/→/← handlers; and add a slim bottom bulk-action bar that appears at ≥2 selected rows. The entire interaction layer is identical in both the FAVORITES (pinned) and OPEN FOLDER (Browse) regions; only the *action set* in the bar differs.

**Architecture:** macOS SwiftUI + SwiftData, all Swift Package Manager (no Xcode project). Two targets: `LumeCore` (pure, unit-tested logic) and `LumeApp` (SwiftUI executable, depends on `LumeCore`). The sidebar is a single `List(selection:)` whose selection is `model.selectedRowIDs: Set<String>`; rows carry `.tag(SidebarRow(...).id)`. Two `FileTreeView` instances (pinned + browser) render the *same* `SidebarItemRow`, so the row view is already section-agnostic. Region differences are carried by `SidebarSection { case pinned, browser }`.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, AppKit interop (`NSViewRepresentable`, `NSClickGestureRecognizer`). Toolchain note: the active CLT lacks the SwiftData macro plugin, so **every** `swift build` / `swift test` MUST be prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The app bundle is built with `tools/build-app.sh` (which already exports `DEVELOPER_DIR`). There is **no UI test target** — SwiftUI surfaces are verified by `swift build` (must compile) + a documented manual checklist run against a real folder via `LUME_OPEN_FOLDER`. Only pure logic extracted into `LumeCore` gets a real `swift test`.

---

## File Structure

| File | New/Modified | Responsibility |
| --- | --- | --- |
| `Sources/LumeCore/RowSelection.swift` | **New** | Pure, target-agnostic selection math: contiguous-range extension over a flat ordered list of row ids (used by the keyboard ⇧↑/⇧↓ handlers and `Select All`). Unit-tested. |
| `Tests/LumeCoreTests/RowSelectionTests.swift` | **New** | `swift test` unit tests for `RowSelection`. |
| `Sources/LumeApp/Sidebar/DoubleClickCatcher.swift` | **New — CONDITIONAL (Candidate B ONLY)** | AppKit `NSClickGestureRecognizer` (count = 2) wrapped in `NSViewRepresentable`. **Created ONLY if the Task 0 spike forces Candidate B.** The PREFERRED outcome (Candidate C) deletes the row-body single-tap and keeps the existing double-tap, needing NO AppKit and NO new file — in which case this row is REMOVED/not-needed. Fires a closure on double-click without consuming single clicks, so native `List(selection:)` keeps ⌘/⇧ multi-select. |
| `Sources/LumeApp/Sidebar/SidebarActionBar.swift` | **New** | The slim bottom bulk-action bar (`safeAreaInset(edge: .bottom)`), shown when `selectedRowIDs.count >= 2`. Section-aware action set. |
| `Sources/LumeApp/Sidebar/FileTreeView.swift` | **Modified** | `SidebarItemRow`: remove the competing row-body `.onTapGesture(count: 1)`; KEEP the existing `.onTapGesture(count: 2)` for double-click drill/open (Candidate C) — or, if the spike forces Candidate B, also remove the double-tap and attach `DoubleClickCatcher`. Keep the disclosure-triangle `.onTapGesture` (already isolated on the chevron). Add an ordered-row-id flattener used by the keyboard range math. |
| `Sources/LumeApp/Sidebar/SidebarView.swift` | **Modified** | Add `.safeAreaInset(edge: .bottom)` for the action bar; add the new key handlers (⇧↑/⇧↓ extend, ⏎ open/drill, ⌘A select all) alongside the existing Space/→/← handlers; build the flat ordered-id list the keyboard math needs. |
| `Sources/LumeApp/AppModel.swift` | **Modified** | Add selection-context helpers the action bar needs: `selectionSection`, `selectionPinState`, `selectionHiddenState`, `pinSelection()`/`unpinSelection()` (the latter exists), `setHiddenForSelection` (exists). Add `orderedVisibleRowIDs` storage + `extendSelection(...)` wrappers that call `RowSelection`. Add `selectAll()` and `openOrDrillSelectedSingle()` reuse. |

No other files change. No SwiftData schema change. No new `Notification.Name`s required (key handling stays List-scoped in `SidebarView`, matching the existing Space/→/← pattern).

---

## Task 0 — RESEARCH SPIKE: decide the double-click + reorder coexistence mechanism

**Goal of this task:** Commit to ONE concrete mechanism for "double-click drill that does NOT re-break native `List(selection:)` multi-select," and confirm it coexists with the FAVORITES `.onMove` drag-to-reorder. The rest of the plan is written against the decision recorded here. Do the spike, record the result in the checkboxes, then proceed.

**Spike philosophy: try the SIMPLEST mechanism first, stop at the first that passes.** Evaluate candidates IN THIS ORDER — **C, then A, then B** — and commit to whichever passes first. Do NOT reach for AppKit until the pure-SwiftUI candidates are proven to fail. The big realization driving this ordering: the thing that breaks native multi-select is almost certainly the *single*-tap gesture, not the double-tap. If so, the smallest possible change (delete one line) is the whole fix and the entire `DoubleClickCatcher` AppKit overlay is unnecessary dead code.

**Files:**
- Spike scratch: `Sources/LumeApp/Sidebar/_spike_DoubleClick.swift` (DELETE before finishing the task) — used ONLY for Candidate A/B if Candidate C is inconclusive in the real list. Candidate C is best validated directly in the real `SidebarView` list, not a toy.
- Reference (read-only): `Sources/LumeApp/Sidebar/FileTreeView.swift:106-163` (current `SidebarItemRow` body + the competing gestures at `149-154`, triangle tap at `113`), `Sources/LumeApp/Sidebar/SidebarView.swift:47-62` & `175-182` (List selection + `.onMove`).

### Background (verified facts — do not re-derive)
- The List is already `List(selection: selection)` where `selection` is a `Binding<Set<String>>` onto `model.selectedRowIDs` (`SidebarView.swift:25-27`, `:47`). Rows carry `.tag(SidebarRow(...).id)` (`FileTreeView.swift:47-48`, `SidebarView.swift:166-167`). So **native ⌘-click toggle and ⇧-click contiguous-range already work for free** the instant we stop intercepting clicks.
- The thing that breaks it today is `SidebarItemRow`'s own `.onTapGesture(count: 1)` (`FileTreeView.swift:154`) and possibly `.onTapGesture(count: 2)` (`:149-153`). A SwiftUI `.onTapGesture` on a List row swallows the click before the List's selection machinery sees it. **Hypothesis (Candidate C): it is the single-tap that does the damage; the double-tap may coexist fine.**
- The disclosure triangle already has its OWN isolated `.onTapGesture { model.toggleExpanded(url) }` scoped to just the 12pt chevron image (`FileTreeView.swift:109-113`). That is fine to keep — it is the Finder "triangle expands, body selects" semantic — as long as the row body no longer carries a *single*-tap gesture.
- FAVORITES reorder is `.onMove` on the pinned `ForEach` (`SidebarView.swift:175-182`). `.onMove` is driven by the List's own drag machinery, independent of row tap gestures.

### Candidate C — delete ONLY the single-tap; keep the existing double-tap (try FIRST, smallest change)
Delete ONLY the `.onTapGesture(count: 1)` at `FileTreeView.swift:154`, and KEEP the existing `.onTapGesture(count: 2)` at `:149-153` for double-click drill/open. **Hypothesis:** the thing breaking native ⌘/⇧ `List(selection:)` multi-select is the *single*-tap gesture, not the double-tap. If true, single-click selection (native) + double-click drill (existing gesture) both work with ZERO AppKit, and `DoubleClickCatcher` is unnecessary dead code. Pro: one-line change, pure SwiftUI, no new file. This is by far the cheapest fix if it holds.

### Candidate A — `simultaneousGesture(TapGesture(count: 2))` (fallback)
If Candidate C's surviving `.onTapGesture(count: 2)` still steals the click stream from the List, replace it with `.simultaneousGesture(TapGesture(count: 2).onEnded { ... })`. `.simultaneousGesture` does not pre-empt the List's selection recognizer the way `.onTapGesture` does — both can fire, so single clicks still reach the List. Pro: pure SwiftUI, no AppKit. Con: a `TapGesture(count: 2)` can still race the List's selection on the *first* click of the pair, and double-click timing is not honored as crisply as a native recognizer; it can also interfere with `.onMove`'s drag-start hit testing.

### Candidate B — AppKit `NSClickGestureRecognizer(numberOfClicksRequired: 2)` via `NSViewRepresentable` overlay (LAST RESORT)
Only if BOTH C and A fail. A transparent overlay view hosting an `NSClickGestureRecognizer` with `numberOfClicksRequired = 2` and `delaysPrimaryMouseButtonEvents = false`. A double-click recognizer by design *should* let single clicks pass through to the responder chain (the List), but this is the mechanically riskiest option: the `hitTest → nil` passthrough is unproven in this List context, and the documented `super.hitTest` + delegate fallback risks re-stealing the single click — reintroducing the exact bug this phase fixes. Do NOT adopt B unless the spike PROVES (against the real list) that single clicks still reach the List AND `.onMove` still works with the overlay attached.

### PASS criteria (concrete, ALL-of — validate in the REAL `List(selection:)`, not a toy)
A candidate PASSES only if ALL FOUR hold, observed in the actual `SidebarView` list (with real `selectedRowIDs` and the real `.onMove`):
1. ⌘-click row A then row B yields `{A, B}` in `model.selectedRowIDs` (and toggles a row back out on repeat ⌘-click).
2. ⇧-click yields a contiguous range in `selectedRowIDs`.
3. A genuine double-click drills (folder) / opens (file) AND does not corrupt the selection.
4. FAVORITES `.onMove` drag-to-reorder still works (drag a top-level favorite up/down; order persists).

Candidate C is validated by directly editing `FileTreeView.swift` (delete the single-tap line) and running the real app via `LUME_OPEN_FOLDER`. Only fall to `_spike_DoubleClick.swift` for A/B if C fails and you want an isolated harness.

### DECISION (commit here — do the spike IN ORDER, then check exactly one CHOSEN line)
- [ ] **Candidate C (try FIRST):** Delete only `.onTapGesture(count: 1)` (`:154`), keep `.onTapGesture(count: 2)` (`:149-153`). Run the real app. Record all four PASS criteria: ⌘-click `{A,B}`? ⇧-click range? double-click drills/opens without corrupting selection? `.onMove` reorders?
- [ ] If C fails, **Candidate A:** swap the surviving double-tap for `.simultaneousGesture(TapGesture(count: 2).onEnded { ... })`. Re-check all four PASS criteria.
- [ ] If A also fails, **Candidate B:** build `_spike_DoubleClick.swift` to PROVE single clicks reach the List and `.onMove` works with the `NSClickGestureRecognizer` overlay before adopting it. Re-check all four PASS criteria.
- [ ] **CHOSEN MECHANISM:** _record exactly one_ — **C (preferred)** / A / B — with one line of evidence per PASS criterion.
- [ ] **If Candidate C (or A) passes: mark Task 1 (`DoubleClickCatcher`) as REMOVED/NOT-NEEDED, do NOT create `Sources/LumeApp/Sidebar/DoubleClickCatcher.swift`, and strike its row from the File Structure table.** Wire Task 3 against the chosen pure-SwiftUI mechanism instead.
- [ ] If (and only if) Candidate B is chosen, record the spike result (one or two lines) as a comment at the top of the new `DoubleClickCatcher.swift` created in Task 1.
- [ ] `rm Sources/LumeApp/Sidebar/_spike_DoubleClick.swift` (if it was created).
- [ ] Verify clean tree: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` succeeds with the spike removed.

> **All later tasks build on the Task 0 decision.** The plan PREFERS Candidate C (delete the single-tap, keep the double-tap; no AppKit, no new file). Task 1 and the `DoubleClickCatcher` file are written below for the Candidate-B-only path and are explicitly conditional: **skip Task 1 entirely unless the spike forces Candidate B.** Task 3 documents both the Candidate-C wiring (default) and the Candidate-B wiring (fallback).

---

## Task 1 — `DoubleClickCatcher` (non-intercepting double-click) — CONDITIONAL (Candidate B ONLY)

> **SKIP THIS ENTIRE TASK unless the Task 0 spike chose Candidate B.** If the spike chose Candidate C (preferred) or Candidate A, do NOT create `DoubleClickCatcher.swift`; the double-click is handled by the existing `.onTapGesture(count: 2)` (C) or a `.simultaneousGesture(TapGesture(count: 2))` (A), wired in Task 3. Mark this task DONE-by-omission and move to Task 2.

**Files:**
- Create: `Sources/LumeApp/Sidebar/DoubleClickCatcher.swift` (ONLY for Candidate B)
- Test: build-only (AppKit interop view; verified manually in Task 4).

### Steps
- [ ] Create `Sources/LumeApp/Sidebar/DoubleClickCatcher.swift` with the complete code below. It overlays a transparent `NSView` carrying an `NSClickGestureRecognizer` requiring two clicks. Single clicks are not consumed, so the underlying SwiftUI List keeps native selection.

```swift
import SwiftUI
import AppKit

/// A transparent overlay that fires `action` on a genuine double-click while
/// letting single clicks fall through to the SwiftUI `List` underneath. We use
/// an AppKit `NSClickGestureRecognizer(numberOfClicksRequired: 2)` because a
/// SwiftUI `.onTapGesture` on a List row swallows the click before the List's
/// `selection:` machinery sees it — which is exactly what broke native ⌘/⇧
/// multi-select. A double-click recognizer, by contrast, ignores single clicks
/// (they pass to the responder chain), so selection and `.onMove` reorder are
/// untouched. (Spike decision: Task 0, Candidate B.)
struct DoubleClickCatcher: NSViewRepresentable {
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        let recognizer = NSClickGestureRecognizer(target: context.coordinator,
                                                  action: #selector(Coordinator.handle))
        recognizer.numberOfClicksRequired = 2
        recognizer.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func handle() { action() }
    }

    /// Transparent to hit-testing for everything EXCEPT the double-click the
    /// recognizer claims, so single clicks reach the List row behind it.
    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Returning nil lets the click pass through to views below; the
            // attached gesture recognizer still observes the event stream and
            // fires on the second click of a double.
            nil
        }
    }
}
```

- [ ] Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` — must compile.

> Note on `hitTest` returning `nil`: gesture recognizers attached to a view observe the window's event stream for that view's region regardless of `hitTest`, so double-clicks still register while single clicks pass through. If the Task 0 spike shows the recognizer does NOT fire with `hitTest` returning nil, change `PassthroughView.hitTest` to `super.hitTest(point)` and instead set the recognizer's `delegate` to allow simultaneous recognition with the List — record whichever variant the spike validated.

---

## Task 2 — Pure selection math in `LumeCore` (`RowSelection`) + unit tests

**Why `LumeCore`:** `LumeCoreTests` depends only on `LumeCore`; `SidebarRow`/`AppModel` live in `LumeApp` and are NOT visible to the test target. So the extractable math must operate on plain `[String]` ordered ids + a `Set<String>` selection, with no `LumeApp` types. The keyboard ⇧↑/⇧↓ handlers and `Select All` call into it.

**Files:**
- Create: `Sources/LumeCore/RowSelection.swift`
- Test: `Tests/LumeCoreTests/RowSelectionTests.swift`

### Steps
- [ ] Create `Sources/LumeCore/RowSelection.swift` with the complete code below.

```swift
import Foundation

/// Pure, view-agnostic selection math over a flat, top-to-bottom ordered list
/// of row ids (the visual order of the sidebar's currently-visible rows).
///
/// Native `List(selection:)` already handles ⌘-click toggle and ⇧-click range
/// for mouse input. These helpers cover the KEYBOARD behaviors (plain ↑/↓ move,
/// ⇧↑/⇧↓ extend, ⌘A select all) where SwiftUI's multi-section, recursively-
/// rendered List gives us no reliable built-in behavior, plus the anchor
/// bookkeeping a contiguous keyboard range needs.
public enum RowSelection {

    /// Move the focused row one step in `order` (down: +1, up: -1), replacing the
    /// selection with the single destination row. Returns the new selection and
    /// the new anchor (the destination). No-op at the ends.
    /// `current` is the row the user is moving FROM (the sole selected / anchor).
    public static func move(from current: String?,
                            in order: [String],
                            by step: Int) -> (selection: Set<String>, anchor: String)? {
        guard !order.isEmpty else { return nil }
        guard let current, let idx = order.firstIndex(of: current) else {
            // Nothing focused yet: land on the first (down) or last (up) row.
            let target = step >= 0 ? order.first! : order.last!
            return ([target], target)
        }
        let next = idx + step
        guard order.indices.contains(next) else { return nil }
        let target = order[next]
        return ([target], target)
    }

    /// Extend a contiguous selection from `anchor` toward `focus + step`.
    /// The selection becomes every row between the anchor and the new focus,
    /// inclusive — exactly Finder's ⇧↑/⇧↓. Returns the new selection and the new
    /// focus (the anchor is unchanged by the caller). No-op at the ends.
    public static func extend(anchor: String,
                              focus: String,
                              in order: [String],
                              by step: Int) -> (selection: Set<String>, focus: String)? {
        guard let anchorIdx = order.firstIndex(of: anchor),
              let focusIdx = order.firstIndex(of: focus) else { return nil }
        let newFocusIdx = focusIdx + step
        guard order.indices.contains(newFocusIdx) else { return nil }
        let lo = min(anchorIdx, newFocusIdx)
        let hi = max(anchorIdx, newFocusIdx)
        return (Set(order[lo...hi]), order[newFocusIdx])
    }

    /// The whole list as a selection (⌘A).
    public static func all(in order: [String]) -> Set<String> { Set(order) }
}
```

- [ ] Create `Tests/LumeCoreTests/RowSelectionTests.swift` with the complete code below (Swift Testing — matches the existing `Tests/LumeCoreTests` style; if the suite uses XCTest instead, mirror that — check a neighboring file first, but Swift Testing `@Test`/`#expect` is correct here).

```swift
import Testing
@testable import LumeCore

@Suite struct RowSelectionTests {
    let order = ["a", "b", "c", "d", "e"]

    @Test func moveDownReplacesSelection() {
        let r = RowSelection.move(from: "b", in: order, by: 1)
        #expect(r?.selection == ["c"])
        #expect(r?.anchor == "c")
    }

    @Test func moveUpReplacesSelection() {
        let r = RowSelection.move(from: "c", in: order, by: -1)
        #expect(r?.selection == ["b"])
        #expect(r?.anchor == "b")
    }

    @Test func moveStopsAtBottom() {
        #expect(RowSelection.move(from: "e", in: order, by: 1) == nil)
    }

    @Test func moveStopsAtTop() {
        #expect(RowSelection.move(from: "a", in: order, by: -1) == nil)
    }

    @Test func moveWithNoFocusLandsOnFirstGoingDown() {
        let r = RowSelection.move(from: nil, in: order, by: 1)
        #expect(r?.selection == ["a"])
    }

    @Test func moveWithNoFocusLandsOnLastGoingUp() {
        let r = RowSelection.move(from: nil, in: order, by: -1)
        #expect(r?.selection == ["e"])
    }

    @Test func extendDownGrowsContiguousRange() {
        let r = RowSelection.extend(anchor: "b", focus: "b", in: order, by: 1)
        #expect(r?.selection == ["b", "c"])
        #expect(r?.focus == "c")
    }

    @Test func extendDownTwiceFromMovingFocus() {
        let first = RowSelection.extend(anchor: "b", focus: "b", in: order, by: 1)!
        let second = RowSelection.extend(anchor: "b", focus: first.focus, in: order, by: 1)!
        #expect(second.selection == ["b", "c", "d"])
        #expect(second.focus == "d")
    }

    @Test func extendUpAcrossAnchorShrinksThenFlips() {
        // anchor c, focus currently e → extend up moves focus to d; range c…d
        let r = RowSelection.extend(anchor: "c", focus: "e", in: order, by: -1)
        #expect(r?.selection == ["c", "d"])
        #expect(r?.focus == "d")
    }

    @Test func extendStopsAtBottomEdge() {
        #expect(RowSelection.extend(anchor: "d", focus: "e", in: order, by: 1) == nil)
    }

    @Test func selectAllReturnsEverything() {
        #expect(RowSelection.all(in: order) == ["a", "b", "c", "d", "e"])
    }

    @Test func emptyOrderIsSafe() {
        #expect(RowSelection.move(from: nil, in: [], by: 1) == nil)
        #expect(RowSelection.all(in: []) == [])
    }
}
```

- [ ] Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RowSelectionTests` — all green.
- [ ] Run the full suite once to confirm no regression: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

---

## Task 3 — Remove competing single-tap; wire disclosure + double-click in `SidebarItemRow`

**Files:**
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift` (`SidebarItemRow.body`, currently lines `106-163`)
- Test: build + manual (Task 4).

> **This task branches on the Task 0 decision.** Use the **Candidate C** wiring below by default (delete only the single-tap, keep the existing double-tap). Use the **Candidate B** wiring ONLY if the spike forced the AppKit overlay.

### Steps — Candidate C (DEFAULT)
- [ ] In `SidebarItemRow.body`, DELETE ONLY the row-body single-tap (currently `FileTreeView.swift:154`):

```swift
        .onTapGesture(count: 1) { if isDirectory { model.toggleExpanded(url) } else { model.selectedFile = url } }
```

- [ ] KEEP the existing double-tap (`FileTreeView.swift:149-153`), but FIX the file branch so a double-click on a FILE sets the SELECTION (not `selectedFile` out-of-band). Setting `model.selectedFile` directly bypasses `selectedRowIDs`, which DESYNCS the List selection, `RowMetaView` (gated on `selectedFile == url` at `FileTreeView.swift:140`), the bulk action bar, and the keyboard helpers that all read `selectedRowIDs`. Instead set the selection and let the existing `onChange(of: selectedRowIDs) → openIfSingleFileSelected()` (`SidebarView`/`AppModel.swift:319-323`) set `selectedFile`, keeping every consumer in sync. Replace the kept gesture with this complete corrected closure:

```swift
        // Double-click = Finder drill/open. The single click is handled by native
        // List(selection:) (so ⌘/⇧ multi-select and .onMove keep working). For a
        // file we set the SELECTION (not selectedFile directly) so the List, the
        // RowMetaView (gated on selectedFile == url), the action bar, and the
        // keyboard helpers all stay in sync — onChange(selectedRowIDs) →
        // openIfSingleFileSelected() then sets selectedFile.
        .onTapGesture(count: 2) {
            if isDirectory {
                model.expandedPaths.remove(url.path)   // collapse any pending inline expand
                model.drillInto(url)
            } else {
                model.selectedRowIDs = [SidebarRow(url: url, isDirectory: false, section: section).id]
            }
        }
```

> Why set the selection rather than no-op: although a single click already opens a file in the new model (native selection → `openIfSingleFileSelected`), making double-click set the selection is the cleaner choice — it keeps `selectedRowIDs`, `selectedFile`, `RowMetaView`, and the action bar provably in sync regardless of how the row was reached, and it does the right thing even if focus/selection had drifted. (A plain no-op for files would also be acceptable, but the selection-setting form is the committed approach.)

### Steps — Candidate B (FALLBACK, only if Task 0 chose B)
- [ ] DELETE BOTH row-body tap gestures (`FileTreeView.swift:149-154`):

```swift
        .onTapGesture(count: 2) {
            guard isDirectory else { return }
            model.expandedPaths.remove(url.path)   // undo the single-tap's pending expand
            model.drillInto(url)
        }
        .onTapGesture(count: 1) { if isDirectory { model.toggleExpanded(url) } else { model.selectedFile = url } }
```

- [ ] Replace them with a single `DoubleClickCatcher` overlay (Finder double-click): folder → drill in, file → set selection (NOT `selectedFile` directly — same sync rationale as Candidate C). Add this `.overlay` to the row's outer `VStack` (after `.contentShape(Rectangle())` at `:145`, replacing the deleted gestures):

```swift
        .contentShape(Rectangle())
        // Drag-to-copy-paths only in the browser; in Favorites it would fight
        // the list's .onMove drag-to-reorder.
        .draggableIf(section == .browser, url)
        // Double-click = Finder drill/open. Single clicks fall through to the
        // List's native selection (so ⌘/⇧ multi-select and .onMove keep working).
        // For a file we set the SELECTION (not selectedFile) so the List,
        // RowMetaView, action bar, and keyboard helpers stay in sync via
        // onChange(selectedRowIDs) → openIfSingleFileSelected().
        .overlay(DoubleClickCatcher {
            if isDirectory {
                model.expandedPaths.remove(url.path)  // collapse any pending inline expand
                model.drillInto(url)
            } else {
                model.selectedRowIDs = [SidebarRow(url: url, isDirectory: false, section: section).id]
            }
        })
        .contextMenu {
```

- [ ] CONFIRM the disclosure triangle keeps its own isolated tap (DO NOT change it). It is already scoped to just the chevron image (`FileTreeView.swift:109-113`):

```swift
                if isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 12)
                        .onTapGesture { model.toggleExpanded(url) }
                } else {
                    Spacer().frame(width: 12)
                }
```

  This satisfies the spec's "the row *body* selects; the *triangle* expands." Because the chevron is a 12pt image with its own `.onTapGesture` and the body no longer has a *single*-tap gesture, the triangle hit-target and selection cannot collide. (Candidate C keeps a row-body `.onTapGesture(count: 2)`; that is double-click-only and does not intercept the single click the List needs for selection.)

- [ ] Update the stale doc comment on `SidebarItemRow` (currently `FileTreeView.swift:91-92`) from "Single-click a folder toggles inline expansion; double-click drills in." to reflect the new model:

```swift
/// One selectable file/folder row. Selection is native (List(selection:)); the
/// disclosure triangle toggles inline expansion, and a double-click drills into
/// a folder / opens a file. Single clicks are NOT intercepted, so ⌘/⇧
/// multi-select works in both regions.
```

- [ ] Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` — must compile.

---

## Task 4 — Keyboard navigation: ⇧↑/⇧↓ extend, ⏎ open/drill, ⌘A select all (+ anchor)

The existing Space (Quick Look), → (expand), ← (collapse) handlers in `SidebarView` stay. We ADD plain ↑/↓ single-row movement, the ⇧↑/⇧↓ range-extend variants, ⏎ open/drill, and ⌘A select-all. Range AND single-row move math both come from `RowSelection` (Task 2), fed a flat ordered-id list.

> **Why ↑/↓ is wired explicitly (not left native).** Although a plain `List(selection:)` moves selection with arrows for free in simple cases, THIS sidebar is a multi-section List built from recursively-injected child `FileTreeView` instances with hand-rolled `.tag` ids — native arrow traversal across that synthesized, multi-region row set is unreliable. So we wire plain ↑/↓ to `RowSelection.move(...)` over the same flat `orderedVisibleRowIDs`, mirroring exactly how ⇧↑/⇧↓ are wired. This also retires the "dead API" smell: `RowSelection.move` is unit-tested (Task 2) and now actually called.

**Files:**
- Modify: `Sources/LumeApp/AppModel.swift` (add ordered-rows storage + anchor + extend/selectAll/open helpers; near the existing selection helpers `:284-335`)
- Modify: `Sources/LumeApp/Sidebar/SidebarView.swift` (build the ordered-id list; add the key handlers in the existing `.onKeyPress` cluster `:67-86`)
- Modify: `Sources/LumeApp/Sidebar/FileTreeView.swift` (publish the flattened visible row ids in render order)
- Test: `swift test` (RowSelection already covers the math) + manual.

### 4a. Flatten the visible rows in render order
The List renders rows recursively across `FileTreeView` instances; there is no single flat list today. The simplest reliable source of "visual order" is to compute it the same way the views do: walk pinned visible favorites (and their expanded children) then the browser tree, applying the same `visibleChildren` filtering. Build it as a pure helper on `AppModel` so both the keyboard handlers and any future feature share one definition.

- [ ] In `AppModel.swift`, add an anchor + an ordered-row-id cache plus its setter (place after `selectedRowIDs` declaration `:41`):

```swift
    /// The row id the most recent contiguous (⇧) keyboard extension is anchored
    /// to, and the row id that currently has keyboard focus within that range.
    /// Reset whenever a plain move/selection replaces the selection.
    @ObservationIgnored var selectionAnchorID: String?
    @ObservationIgnored var selectionFocusID: String?

    /// Flat, top-to-bottom order of the currently-visible sidebar row ids.
    /// Published by `SidebarView` each render so keyboard range math (which has
    /// no view tree) can resolve neighbors. Not observed (read on key events).
    @ObservationIgnored var orderedVisibleRowIDs: [String] = []
```

- [ ] In `AppModel.swift`, add the keyboard command helpers (place near `openIfSingleFileSelected()` `:319`):

```swift
    /// ⌘A — select every visible row.
    func selectAllVisibleRows() {
        selectedRowIDs = RowSelection.all(in: orderedVisibleRowIDs)
        selectionAnchorID = orderedVisibleRowIDs.first
        selectionFocusID = orderedVisibleRowIDs.last
    }

    /// ↑ / ↓ (no modifier) — move the single selection one row in the flat
    /// visible order, replacing it (Finder plain-arrow). Re-anchors so a later
    /// ⇧-extend starts fresh from the moved-to row. Wired explicitly because
    /// native arrow traversal across this multi-section, recursively-rendered
    /// List is unreliable.
    func moveSelection(by step: Int) {
        let current = soleSelectedRowID ?? selectionFocusID ?? selectionAnchorID
        guard let r = RowSelection.move(from: current, in: orderedVisibleRowIDs, by: step) else { return }
        selectedRowIDs = r.selection
        selectionAnchorID = r.anchor
        selectionFocusID = r.anchor
    }

    /// ⇧↑ / ⇧↓ — extend a contiguous selection from the anchor. Seeds the anchor
    /// from the current sole selection on first use.
    func extendSelection(by step: Int) {
        if selectionAnchorID == nil { selectionAnchorID = soleSelectedRowID ?? orderedVisibleRowIDs.first }
        if selectionFocusID == nil { selectionFocusID = selectionAnchorID }
        guard let anchor = selectionAnchorID, let focus = selectionFocusID,
              let r = RowSelection.extend(anchor: anchor, focus: focus,
                                          in: orderedVisibleRowIDs, by: step) else { return }
        selectedRowIDs = r.selection
        selectionFocusID = r.focus
    }

    /// ⏎ — open the sole selected file, or drill into the sole selected folder.
    /// Reuses the existing single-row open/drill behavior.
    func activateSelectedRow() { openOrDrillSelected() }
```

- [ ] In `AppModel.openIfSingleFileSelected()` and any plain-move path, reset the anchor when the selection collapses to one row so a later ⇧-extend re-anchors correctly. Append to `openIfSingleFileSelected()`:

```swift
    func openIfSingleFileSelected() {
        if let id = soleSelectedRowID {
            // A fresh single selection becomes the new anchor for ⇧-extends.
            selectionAnchorID = id
            selectionFocusID = id
        }
        guard let id = soleSelectedRowID,
              let row = SidebarRow.decode(id), !row.isDirectory else { return }
        selectedFile = row.url
    }
```

### 4b. Publish the ordered ids from `SidebarView`
- [ ] In `SidebarView.swift`, add a computed property that produces the flat visible order, reusing the same filtering the rows use. Add it near `visibleFavorites` (`:42-44`):

```swift
    /// Flat top-to-bottom order of every visible row id, matching what the List
    /// actually renders (pinned region, then expanded pinned children, then the
    /// browser tree). Feeds the keyboard range math in `AppModel`.
    private var orderedRowIDs: [String] {
        var ids: [String] = []

        func walk(_ url: URL, isDir: Bool, section: SidebarSection, includeHidden: Bool) {
            ids.append(SidebarRow(url: url, isDirectory: isDir, section: section).id)
            guard isDir, model.expandedPaths.contains(url.path) else { return }
            for child in visibleChildren(of: url, section: section, includeHidden: includeHidden) {
                walk(child.url, isDir: child.isDirectory, section: section, includeHidden: includeHidden)
            }
        }

        for fav in visibleFavorites {
            walk(URL(fileURLWithPath: fav.path), isDir: fav.kindRaw == "folder",
                 section: .pinned, includeHidden: false)
        }
        if let root = model.browseRoot {
            for child in visibleChildren(of: root, section: .browser,
                                         includeHidden: model.showBrowserHidden) {
                walk(child.url, isDir: child.isDirectory, section: .browser,
                     includeHidden: model.showBrowserHidden)
            }
        }
        return ids
    }

    /// The same filtering `FileTreeView.visibleChildren` applies, hoisted here so
    /// the keyboard order matches the rendered order exactly.
    private func visibleChildren(of parent: URL, section: SidebarSection,
                                 includeHidden: Bool) -> [FileNode] {
        var nodes = model.children(of: parent, includeHidden: includeHidden)
        if model.filesOnly { nodes = nodes.filter { !$0.isDirectory } }
        if section == .pinned, !model.showPinnedHidden {
            nodes = nodes.filter { !hiddenPaths.contains($0.url.path) }
        }
        if let tag = model.activeTagFilter {
            let allowed = model.store?.paths(taggedWith: tag) ?? []
            nodes = nodes.filter { $0.isDirectory || allowed.contains($0.url.path) }
        }
        if !model.browseFilter.isEmpty {
            nodes = nodes.filter { $0.isDirectory || $0.name.localizedCaseInsensitiveContains(model.browseFilter) }
        }
        return nodes
    }
```

> ⚠️ **CROSS-PHASE DRIFT RISK — Phase C MUST reconcile both copies.** This `visibleChildren` helper DUPLICATES `FileTreeView.visibleChildren`'s filtering logic, INCLUDING the soon-to-be-replaced `model.activeTagFilter` branch. Phase C replaces `activeTagFilter` (single) with set-based `activeTagFilters` and rewrites `FileTreeView.visibleChildren`. When it does, it MUST update BOTH the `FileTreeView.visibleChildren` rewrite AND this `SidebarView.orderedRowIDs` copy so they stay byte-for-byte identical — they are a single conceptual source of truth for "visible, filtered, ordered children," and if they drift the keyboard order silently diverges from the rendered order (arrows skip/repeat rows). For Phase B keep it local and add a code comment cross-referencing `FileTreeView.swift:66-83`. See the explicit cross-phase note in Self-Review below; flag this dependency in the commit message so Phase C's executor sees it.

- [ ] Keep `model.orderedVisibleRowIDs` fresh: in `SidebarView.body`, on the `List`, publish the order whenever the inputs change. Add after the existing `.onChange(of: model.selectedRowIDs)` (`:62`):

```swift
        .onChange(of: orderedRowIDs) { _, new in model.orderedVisibleRowIDs = new }
        .onAppear { model.orderedVisibleRowIDs = orderedRowIDs }
```

### 4c. Add the key handlers
- [ ] In `SidebarView.swift`, in the existing List-scoped `.onKeyPress` cluster (after the `.leftArrow` handler `:80-86`), add the new handlers. These fire only when the List (not a text field) is first responder, matching the existing pattern.

```swift
        .onKeyPress(keys: [.upArrow], phases: .down) { press in
            if press.modifiers.contains(.shift) {
                model.extendSelection(by: -1)
            } else if press.modifiers.isEmpty {
                model.moveSelection(by: -1)
            } else {
                return .ignored
            }
            return .handled
        }
        .onKeyPress(keys: [.downArrow], phases: .down) { press in
            if press.modifiers.contains(.shift) {
                model.extendSelection(by: 1)
            } else if press.modifiers.isEmpty {
                model.moveSelection(by: 1)
            } else {
                return .ignored
            }
            return .handled
        }
        .onKeyPress(.return) {
            guard model.soleSelectedRowID != nil else { return .ignored }
            model.activateSelectedRow()
            return .handled
        }
        .onKeyPress(keys: ["a"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            model.selectAllVisibleRows()
            return .handled
        }
```

> `.onKeyPress(keys:phases:)` with a `KeyPress` predicate is the API that exposes `.modifiers`, so plain ↑/↓, ⇧+arrow, and ⌘A can all be distinguished in one handler. Plain ↑/↓ (no modifier) call `model.moveSelection(by:)` — wired explicitly because native arrow traversal across this multi-section, recursively-rendered List is unreliable; `moveSelection` sets a single selection (which fires `onChange → openIfSingleFileSelected`, re-anchoring) using the unit-tested `RowSelection.move`. ⇧+arrow extends; any other modifier combination returns `.ignored`. ⌘C / ⌥⌘C copy-paths remain provided by `RowMenu`'s `.keyboardShortcut("c", modifiers: [.option, .command])` (`FileTreeView.swift:259-262`) — DO NOT duplicate them here.

- [ ] Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` — must compile.
- [ ] Run tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — green.

### Manual verification checklist (Tasks 3 + 4) — run the app via `LUME_OPEN_FOLDER`
- [ ] Build & launch: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && LUME_OPEN_FOLDER="$HOME/Developer/lume" .build/debug/LumeApp`
- [ ] **Click** a file → it selects and opens in the editor.
- [ ] **⌘-click** a second file → both selected (toggles in/out on repeat). (native, now un-broken)
- [ ] **⇧-click** a row → contiguous range from the anchor selected. (native)
- [ ] **Disclosure triangle** click on a folder → expands/collapses WITHOUT selecting the row.
- [ ] **Click folder body** (not the triangle) → folder row selects, does NOT expand.
- [ ] **Double-click folder** → drills in (browse root changes); **double-click file** → selects it (which opens it via `onChange → openIfSingleFileSelected`) AND the List selection / RowMetaView stay in sync (no out-of-band `selectedFile`).
- [ ] **↓ / ↑** (keyboard, no modifier) → moves the single selection one row in visual order; stops at the ends; opens the file when it lands on one.
- [ ] **⇧↓ / ⇧↑** (keyboard) → extends/contracts the contiguous selection from the anchor; stops at the ends.
- [ ] **⏎** on a single selected folder drills; on a single file opens.
- [ ] **⌘A** selects every visible row.
- [ ] **Space** still Quick Looks the sole selected file; **→/←** still expand/collapse the sole selected folder. (regression)
- [ ] **⌘C / ⌥⌘C** still copy path(s). (regression)
- [ ] Same checks in BOTH the FAVORITES region (expand a pinned folder) and the OPEN FOLDER region — behavior is identical.
- [ ] **FAVORITES drag-to-reorder** (`.onMove`) still works: drag a top-level favorite up/down; order persists. (regression — the integration concern)
- [ ] **RowMetaView** still appears under a singly-selected file and its inline tag chips/editor work (Phase-1). (integration concern)

---

## Task 5 — Bulk action bar (`safeAreaInset(edge: .bottom)`, section-aware)

Appears when `selectedRowIDs.count >= 2`. Slim bottom bar with the count + contextual actions. The bar view is section-agnostic; the action SET branches on the selection's context (which region the selected rows live in, derived from row ids).

**Files:**
- Create: `Sources/LumeApp/Sidebar/SidebarActionBar.swift`
- Modify: `Sources/LumeApp/AppModel.swift` (selection-context derivations + `pinSelection()`)
- Modify: `Sources/LumeApp/Sidebar/SidebarView.swift` (attach `.safeAreaInset(edge: .bottom)`)
- Test: build + manual.

### 5a. Selection-context helpers in `AppModel`
- [ ] In `AppModel.swift`, add context derivations the bar reads. The section is encoded in each row id's first segment (`pinned`/`browser`). Place near `selectedURLs` (`:300`):

```swift
    /// The section the current multi-selection belongs to, if uniform.
    /// (Mixed pinned+browser selections fall back to `.browser` for the action
    /// set — pin/open semantics still make sense.) Derived from row id prefixes.
    var selectionSection: SidebarSection {
        let sections = Set(selectedRowIDs.compactMap { $0.split(separator: "|").first.map(String.init) })
        return sections == ["pinned"] ? .pinned : .browser
    }

    /// True when every selected path is already pinned (drives Pin vs Unpin).
    var selectionIsAllPinned: Bool {
        let urls = selectedURLs
        return !urls.isEmpty && urls.allSatisfy { isPinned($0) }
    }

    /// Pin every selected path that isn't already pinned (Browse action-bar Pin).
    func pinSelection() {
        guard let store else { return }
        for id in selectedRowIDs {
            guard let row = SidebarRow.decode(id), !store.isFavorite(path: row.url.path) else { continue }
            if row.isDirectory { store.addFavoriteFolder(path: row.url.path) }
            else { store.addFavorite(path: row.url.path,
                                     kind: FileKind.detect(filename: row.url.lastPathComponent)) }
        }
    }
```

> `unpinSelection()` (`:198-201`), `setHiddenForSelection(_:)` (`:181-184`), `selectionIsAllHidden(_:)` (`:175-178`), `copyPaths()` (`:165-172`), and `editingTagsForSelection` (`:45`, opens `MultiTagSheet`) already exist and are reused as-is.

### 5b. The action-bar view
- [ ] Create `Sources/LumeApp/Sidebar/SidebarActionBar.swift` with the complete code below. It receives `hiddenPaths` (already derived reactively in `SidebarView`) so the Hide/Unhide label is correct.

```swift
import SwiftUI
import LumeCore

/// Slim bottom bar shown when 2+ sidebar rows are selected. Section-agnostic
/// shell; the action SET branches on `model.selectionSection`. Mirrors the
/// per-row context menu (`RowMenu`) but for the whole multi-selection.
struct SidebarActionBar: View {
    let model: AppModel
    let hiddenPaths: Set<String>

    private var count: Int { model.selectedRowIDs.count }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(count) selected")
                .font(.caption).foregroundStyle(.secondary)

            Spacer(minLength: 0)

            // Copy Paths — always available.
            Button { model.copyPaths() } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .help("Copy Paths")

            // Tag… — bulk tag editor (existing MultiTagSheet).
            Button {
                model.notesOpenPath = nil
                model.editingTagsForSelection = true
            } label: {
                Image(systemName: "tag")
            }
            .help("Tag…")

            if model.selectionSection == .browser {
                // Browse: Pin (or Unpin if all already pinned).
                let allPinned = model.selectionIsAllPinned
                Button { allPinned ? model.unpinSelection() : model.pinSelection() } label: {
                    Image(systemName: allPinned ? "pin.slash" : "pin")
                }
                .help(allPinned ? "Unpin" : "Pin")
            } else {
                // Favorites: Unpin + Hide/Unhide curation.
                Button { model.unpinSelection() } label: {
                    Image(systemName: "pin.slash")
                }
                .help("Unpin")

                let allHidden = model.selectionIsAllHidden(hiddenPaths)
                Button { model.setHiddenForSelection(!allHidden) } label: {
                    Image(systemName: allHidden ? "eye" : "eye.slash")
                }
                .help(allHidden ? "Un-hide" : "Hide")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }
}
```

### 5c. Attach the bar in `SidebarView`
- [ ] In `SidebarView.swift`, add a `.safeAreaInset(edge: .bottom)` to the `List` (alongside the existing `.safeAreaInset(edge: .top) { topBar }` at `:53`):

```swift
        .safeAreaInset(edge: .top) { topBar }
        .safeAreaInset(edge: .bottom) {
            if model.selectedRowIDs.count >= 2 {
                SidebarActionBar(model: model, hiddenPaths: hiddenPaths)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.selectedRowIDs.count >= 2)
```

- [ ] Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` — must compile.

### Manual verification checklist (Task 5)
- [ ] Select 1 row → no bar. Select a 2nd → bar slides up showing "2 selected".
- [ ] **Copy Paths** button writes the selected paths (paste into a text editor to confirm).
- [ ] **Tag…** opens `MultiTagSheet`; applying tags writes through to all selected files.
- [ ] In **Browse**: multi-select files → bar shows **Pin**; after pinning, re-selecting them shows **Unpin**.
- [ ] In **FAVORITES**: multi-select pinned items → bar shows **Unpin** + **Hide/Unhide**; Hide dims them (toggle `showPinnedHidden` to confirm).
- [ ] Deselecting back to <2 hides the bar.

---

## Task 6 — Final integration pass & regression sweep

**Files:** all of the above. **Test:** build + full `swift test` + manual.

### Steps
- [ ] Full build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`.
- [ ] Full tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — all suites green (existing tag/copy-paths/displayname/breadcrumb tests + new `RowSelectionTests`).
- [ ] App bundle smoke: `tools/build-app.sh` completes and produces `dist/Lume.app`.
- [ ] Confirm the spike scratch file is gone: `Sources/LumeApp/Sidebar/_spike_DoubleClick.swift` must NOT exist.
- [ ] Re-run the three "Known integration concerns" explicitly:
  - [ ] **Drag-reorder coexistence:** in FAVORITES, ⌘-multi-select two top-level favorites, then drag a favorite to reorder — reorder still persists and selection isn't corrupted.
  - [ ] **Triangle vs select:** clicking the disclosure triangle never changes `selectedRowIDs`; clicking the folder body never toggles expansion.
  - [ ] **RowMetaView trigger:** selecting exactly one file still renders `RowMetaView` with working inline tag chips/editor and notes.
- [ ] Confirm no `.onTapGesture(count: 1)` remains on the row BODY in `FileTreeView.swift`: grep `grep -n "onTapGesture(count: 1)" Sources/LumeApp/Sidebar/FileTreeView.swift` — expect ZERO hits. Then `grep -n "onTapGesture" Sources/LumeApp/Sidebar/FileTreeView.swift`:
  - **Candidate C:** expect exactly TWO hits — the chevron `.onTapGesture` AND the row-body `.onTapGesture(count: 2)` double-click. Neither intercepts the single click.
  - **Candidate B:** expect exactly ONE hit — the chevron only (double-click moved to the `DoubleClickCatcher` overlay).

---

## Self-Review

### Cross-Phase Dependencies (READ before Phase C)
- ⚠️ **`orderedRowIDs` duplicates `visibleChildren` filtering — Phase C must reconcile BOTH.** Phase B synthesizes a flat `orderedRowIDs` in `SidebarView` (Task 4b) that duplicates `FileTreeView.visibleChildren`'s filter logic, including the `model.activeTagFilter` branch. Phase C replaces `activeTagFilter` with set-based `activeTagFilters` and rewrites `FileTreeView.visibleChildren`. **Phase C MUST apply that rewrite to BOTH call sites** (`FileTreeView.visibleChildren` AND `SidebarView.visibleChildren`/`orderedRowIDs`) so they remain identical — a single source of truth for "visible, filtered, ordered children." If they drift, the keyboard arrow/range order diverges from what is rendered (rows skipped or revisited). This is a known, accepted duplication in Phase B; the consolidation/reconciliation is explicitly deferred to and REQUIRED of Phase C. Flag it in the Phase B commit message.

### Every Pillar ② spec requirement → task
| Spec requirement (lines) | Task |
| --- | --- |
| Stop overloading single-click; lean on native `List(selection:)` (58–59, 62) | Task 3 (remove the row-body `.onTapGesture(count: 1)`; Candidate C keeps the `(count: 2)` double-tap, Candidate B removes it too) |
| ⌘-click toggle, ⇧-click range (63–64) | Native, unblocked by Task 3; verified in Task 4 checklist |
| Disclosure triangle expands; body selects; single-click no longer auto-expands (65) | Task 3 (keep chevron tap, remove body tap; doc-comment update) |
| Double-click folder drill / file open, non-intercepting mechanism, research step resolves it (66) | Task 0 (decision — PREFERS Candidate C: keep existing double-tap, no AppKit) + Task 3 (wire); Task 1 (`DoubleClickCatcher`) only if Candidate B |
| Keyboard ↑/↓ move, ⇧↑/⇧↓ extend, →/← expand/collapse, ⏎ open, Space QL, ⌘A select all, ⌘C/⌥⌘C copy (67) | Task 4 (↑/↓ via `RowSelection.move`, ⇧↑/⇧↓ extend, ⏎, ⌘A new; →/←/Space/⌘C reused) |
| Bulk action bar at ≥2, `safeAreaInset(edge:.bottom)`, count + contextual actions (Copy Paths, Tag…, Pin/Unpin, Hide/Unhide), branch on context (70–71) | Task 5 |
| Section-agnostic row/selection/triangles/keyboard/bar; both `FileTreeView` instances; region-specific only in action set + `.onMove` + Hide (73–74) | Tasks 3–5 operate on shared `SidebarItemRow`/`SidebarView`; bar branches on `selectionSection` |
| Integration concern: drag-reorder coexistence (77) | Task 0 (confirm) + Task 4 & 6 checklist |
| Integration concern: triangle hit-target vs select (78) | Task 3 + Task 6 checklist |
| Integration concern: RowMetaView still works (79) | Task 4 & 6 checklist |
| Testing: pure math unit-tested in `Tests/LumeCoreTests`; views build+manual; DEVELOPER_DIR (spec 22, 116–120) | Task 2 (`RowSelectionTests`); every task's build/manual steps prefix DEVELOPER_DIR |

### Placeholder scan
- No `TODO`, `FIXME`, `...`, or `<placeholder>` tokens remain in any code block. Every method body, view body, and test is complete.

### Type/signature consistency (verified against the codebase)
- `model.selectedRowIDs: Set<String>` ✓ (`AppModel.swift:41`); `selection` binding ✓ (`SidebarView.swift:25-27`).
- `SidebarRow(url:isDirectory:section:).id` and `SidebarRow.decode(_:)` ✓ (`SidebarRow.swift`).
- `SidebarSection { case pinned, browser }` ✓ (`SidebarRow.swift:5`).
- Reused AppModel members: `copyPaths()` ✓, `unpinSelection()` ✓, `setHiddenForSelection(_:)` ✓, `selectionIsAllHidden(_:)` ✓, `editingTagsForSelection` ✓, `drillInto(_:)` ✓, `expandedPaths` ✓, `toggleExpanded(_:)` ✓, `openOrDrillSelected()` ✓, `soleSelectedRowID` ✓, `openIfSingleFileSelected()` ✓, `children(of:includeHidden:)` ✓, `store?.paths(taggedWith:)` ✓, `activeTagFilter` ✓, `browseFilter`/`filesOnly`/`showPinnedHidden`/`showBrowserHidden` ✓.
- Reused store ops on `LibraryStore`: `isFavorite(path:)`, `addFavorite(path:kind:)`, `addFavoriteFolder(path:)` ✓ (used by existing `toggleFavorite`).
- `Favorite.kindRaw == "folder"` ✓ (matches `SidebarView.swift:160`).
- `MultiTagSheet` opened via `model.editingTagsForSelection = true` ✓ (`SidebarView.swift:56-61`).
- New public API in `LumeCore`: `RowSelection.move/extend/all` — operate only on `[String]`/`Set<String>` (no `LumeApp` types), so `LumeCoreTests` (which depends only on `LumeCore`) can import and test them. ✓
- `.onKeyPress(keys:phases:)` predicate form exposes `KeyPress.modifiers` to distinguish plain ↑/↓ (→ `moveSelection`), ⇧+arrow (→ `extendSelection`), and ⌘A in one handler. ✓
- `RowSelection.move(...)` is now CALLED by `AppModel.moveSelection(by:)` for plain ↑/↓ (not dead API). ✓

### Known spec ambiguities / codebase mismatches surfaced during research
1. **⌘C/⌥⌘C "exists" is partly true.** Copy-paths is only bound through `RowMenu`'s `.keyboardShortcut("c", modifiers: [.option, .command])` (`FileTreeView.swift:262`), i.e. it works when a row is selected because the context-menu shortcut is live. There is no standalone List `.onKeyPress` for it. The plan reuses the existing binding and does NOT add a duplicate (would double-fire). Plain ⌘C (no ⌥) is not currently bound; spec line 67 lists both — left as-is to avoid scope creep, flag for Phase C if needed.
2. **⌘A select-all did not exist** — genuinely new (Task 4). Spec line 67 lists it as if extending existing handlers; it is additive.
3. **No flat row order existed.** ⇧-click range is native (mouse), but the *keyboard* plain ↑/↓ move, ⇧↑/⇧↓ extend, and ⌘A need a flat visual order, which had to be synthesized in `SidebarView.orderedRowIDs` by duplicating `FileTreeView.visibleChildren`'s filter logic (including the `activeTagFilter` branch). **This duplication is a real drift risk and is called out explicitly in the Cross-Phase Dependencies section above: Phase C MUST reconcile the `visibleChildren` rewrite AND this `orderedRowIDs` copy together.** Documented inline at the helper too.
4. **`selectedURLs` ordering is lexicographic, not visual.** `AppModel.selectedURLs` uses `selectedRowIDs.sorted()` (`:300-302`) — fine for Copy Paths (Finder also doesn't guarantee visual order there), but it means the action bar's path order is id-sorted, not top-to-bottom. Acceptable for Phase B; noted.
5. **Double-click mechanism is resolved by the Task 0 spike, simplest-first.** The plan PREFERS Candidate C (delete only the row-body single-tap, keep the existing `.onTapGesture(count: 2)`; no AppKit, no new file), falls to Candidate A (`.simultaneousGesture(TapGesture(count: 2))`), and only as a last resort to Candidate B (the AppKit `DoubleClickCatcher`). The earlier concern — `DoubleClickCatcher.hitTest` returning nil being runtime-uncertain — is now contained: B is reached only if C and A both fail AND the spike PROVES single clicks reach the List and `.onMove` works with the overlay. Execution never stalls because the cheapest candidate is tried first and each has a defined fallback.
