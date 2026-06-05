import SwiftUI
import SwiftData
import LumeCore
import LumeUI

/// The Manage Tags panel (Pillar ③). Curate the tag *vocabulary*: recolor,
/// inline-rename, multi-select, and Merge / Rename / Color / Delete from a
/// footer. Reuses `TagChip`/`TagSwatchPicker` and the tested `LibraryStore` ops
/// (`renameTag`, `recolorTag`, `deleteTag`, `mergeTags`). Opened from the ⚙ in
/// the sidebar Tags header.
struct TagManagerSheet: View {
    let model: AppModel
    @Binding var isPresented: Bool

    @Query(sort: \Tag.name) private var allTags: [Tag]

    @State private var search = ""
    /// Checkbox selection — tag names.
    @State private var selection: Set<String> = []
    /// Drives the single-tag rename sheet.
    @State private var renaming: TagRef?
    /// Drives the bulk color popover.
    @State private var pickingColor = false
    /// Drives the inline merge composer.
    @State private var merging = false
    @State private var mergeSurvivor = ""
    @State private var mergeColorIndex = 0

    // Route ALL mutations through `model.store` (built from `AppModel.libraryContext`),
    // NOT a fresh `LibraryStore(context: <environment modelContext>)`. The rest of
    // the app — including the sidebar's `@Query(sort: \Tag.name) tags` — mutates
    // through `model.store`. If the environment `modelContext` and
    // `AppModel.libraryContext` were ever distinct `ModelContext` instances, a
    // sheet-local store would write to a different context: recolor/rename/merge/
    // delete would NOT propagate to the sidebar's `@Query`, and you could hit save
    // conflicts. (`ContentView` does `model.libraryContext = context`, so today
    // they are the same instance — but this routing keeps it correct even if that
    // wiring changes.) The `@Query` above still observes the environment container,
    // which is fine for read-only display; writes go through `store` below.
    private var store: LibraryStore? { model.store }

    private var filtered: [Tag] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allTags }
        return allTags.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var selectedNames: [String] { selection.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            if merging { mergeComposer } else { footer }
        }
        .frame(width: 420, height: 460)
        .sheet(item: $renaming) { ref in
            TagRenameSheet(model: model, oldName: ref.name) {
                // Drop the old name from selection/filters; the renamed/merged
                // tag may not match the old name anymore.
                selection.remove(ref.name)
                renaming = nil
            }
        }
    }

    // MARK: Header (title + search + Done)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Manage Tags").font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Search tags…", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        }
        .padding(16)
    }

    // MARK: List of tags

    private var list: some View {
        List {
            ForEach(filtered) { tag in
                row(for: tag)
            }
        }
        .listStyle(.inset)
    }

    private func row(for tag: Tag) -> some View {
        let name = tag.name
        let isOn = selection.contains(name)
        let count = store?.files(taggedWith: name).count ?? 0
        return HStack(spacing: 10) {
            Button {
                if isOn { selection.remove(name) } else { selection.insert(name) }
            } label: {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            swatchButton(for: name, colorIndex: tag.colorIndex)

            // Inline rename committed on submit/blur. Routes through `model.store`.
            InlineTagName(name: name, store: store) { old in
                selection.remove(old)
            }

            Spacer(minLength: 0)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// A color swatch dot that opens a recolor popover for one tag.
    private func swatchButton(for name: String, colorIndex: Int) -> some View {
        SingleSwatch(name: name, colorIndex: colorIndex, store: store)
    }
    // NOTE: `store` is `LibraryStore?` (it is `model.store`). `SingleSwatch` and
    // `InlineTagName` take an optional store and no-op when it is nil.

    // MARK: Footer (Merge / Rename / Color / Delete)

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(selection.count) selected")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Merge…") { beginMerge() }
                .disabled(selection.count < 2)
            Button("Rename…") {
                if let only = selectedNames.first, selection.count == 1 {
                    renaming = TagRef(name: only)
                }
            }
            .disabled(selection.count != 1)
            Button("Color") { pickingColor = true }
                .disabled(selection.isEmpty)
                .popover(isPresented: $pickingColor, arrowEdge: .top) {
                    // Seed from the selected tag's existing color when exactly one
                    // is selected (mirrors how the merge composer seeds
                    // mergeColorIndex). For a multi-select there's no single source
                    // color, so fall back to 0.
                    let seed = selection.count == 1
                        ? (store?.colorIndex(forTagNamed: selectedNames[0]) ?? 0)
                        : 0
                    TagSwatchPicker(current: seed) { idx in
                        for n in selectedNames { store?.recolorTag(named: n, colorIndex: idx) }
                        pickingColor = false
                    }
                }
            Button("Delete", role: .destructive) {
                for n in selectedNames {
                    store?.deleteTag(named: n)
                }
                selection.removeAll()
            }
            .disabled(selection.isEmpty)
        }
        .padding(16)
    }

    // MARK: Merge composer (survivor name + color)

    private func beginMerge() {
        mergeSurvivor = selectedNames.first ?? ""
        mergeColorIndex = store?.colorIndex(forTagNamed: mergeSurvivor) ?? 0
        merging = true
    }

    private var mergeComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Merge \(selection.count) tags").font(.subheadline.bold())
            HStack(spacing: 8) {
                Text("Into:").foregroundStyle(.secondary)
                TextField("Survivor name", text: $mergeSurvivor)
                    .textFieldStyle(.roundedBorder)
            }
            TagSwatchPicker(current: mergeColorIndex) { mergeColorIndex = $0 }
            HStack {
                Spacer()
                Button("Cancel") { merging = false }
                    .keyboardShortcut(.cancelAction)
                Button("Merge") {
                    let survivor = mergeSurvivor.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !survivor.isEmpty else { return }
                    let names = selectedNames
                    store?.mergeTags(names, into: survivor, colorIndex: mergeColorIndex)
                    selection = [survivor]
                    merging = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(mergeSurvivor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }
}

/// A single recolor swatch dot (one tag) with a popover picker. `store` is
/// optional (it is `model.store`); a nil store no-ops the recolor.
private struct SingleSwatch: View {
    let name: String
    let colorIndex: Int
    let store: LibraryStore?
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            Circle().fill(tagColor(colorIndex)).frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .help("Change color")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            TagSwatchPicker(current: colorIndex) { idx in
                store?.recolorTag(named: name, colorIndex: idx)
                picking = false
            }
        }
    }
}

/// Inline tag-name editor. Commits on submit/blur via `renameTag` (which merges
/// on a name clash). `onRenamed(oldName)` lets the parent prune stale selection.
/// `store` is optional (it is `model.store`); a nil store no-ops the rename.
private struct InlineTagName: View {
    let name: String
    let store: LibraryStore?
    let onRenamed: (String) -> Void

    @State private var text = ""
    @State private var didInit = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Tag name", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear { if !didInit { text = name; didInit = true } }
            .onSubmit(commit)
            .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name else { text = name; return }
        if store?.renameTag(named: name, to: trimmed) == true {
            onRenamed(name)
        } else {
            text = name   // rejected (or no store) — restore
        }
    }
}
