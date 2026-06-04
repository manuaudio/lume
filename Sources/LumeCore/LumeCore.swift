/// LumeCore — umbrella facade over the focused Lume frameworks.
///
/// Re-exports the app-agnostic kits so existing `import LumeCore` call sites keep
/// working while the real module boundaries are compiler-enforced. New code should
/// prefer importing the specific kit it needs.
@_exported import FileSystemKit
@_exported import LibraryKit
@_exported import DocumentKit
@_exported import ConfigKit
@_exported import SelectionKit

public enum LumeCore {
    public static let version = "0.1.0"
}
