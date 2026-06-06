import SwiftUI
import LumeKit

struct FileRowView: View {
    let node: FileNode
    @Environment(AppState.self) private var app
    @State private var expanded = false
    @State private var children: [FileNode] = []

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(children) { child in
                    FileRowView(node: child)
                }
            } label: {
                Label(node.name, systemImage: "folder")
            }
            .onChange(of: expanded) { _, isOpen in
                if isOpen && children.isEmpty {
                    children = app.children(of: node.url)
                }
            }
        } else {
            Label(node.name, systemImage: "doc.text")
                .tag(node.url)
        }
    }
}
