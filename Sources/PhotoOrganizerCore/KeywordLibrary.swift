import Foundation

/// A keyword vocabulary stored as a tab-indented text file: the format Lightroom and Adobe Bridge use
/// to import and export keywords, so the same file can be shared between them.
///
/// ```
/// Places
/// 	Iceland
/// 		Vík
/// [People]          <- brackets: a category, in Lightroom terms
/// 	Anna
/// 	{Annie}       <- braces: synonym of the line above (preserved, not used)
/// ```
public struct KeywordLibrary: Equatable, Sendable {
    /// Every keyword as a full path ("Places|Iceland|Vík"), parents included, in file order.
    public private(set) var paths: [String] = []
    /// Synonym lines keyed by the keyword path they belong to (kept so saving doesn't lose them).
    private var synonyms: [String: [String]] = [:]
    private var categories: Set<String> = []

    public init(paths: [String] = []) {
        for path in paths { add(path) }
    }

    public init(text: String) {
        var stack: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let depth = rawLine.prefix(while: { $0 == "\t" }).count
            var name = rawLine.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if name.hasPrefix("{"), name.hasSuffix("}") {
                if let owner = stack.last.map({ _ in stack.joined(separator: "|") }) {
                    synonyms[owner, default: []].append(name)
                }
                continue
            }
            var isCategory = false
            if name.hasPrefix("["), name.hasSuffix("]") {
                name = String(name.dropFirst().dropLast())
                isCategory = true
            }
            stack = Array(stack.prefix(min(depth, stack.count)))
            stack.append(name.replacingOccurrences(of: "|", with: "/"))
            let path = stack.joined(separator: "|")
            if isCategory { categories.insert(path.lowercased()) }
            if !contains(path) { paths.append(path) }
        }
    }

    public func contains(_ path: String) -> Bool {
        let lower = Keyword.normalize(path).lowercased()
        return paths.contains { $0.lowercased() == lower }
    }

    /// Adds a keyword path and any missing parents.
    public mutating func add(_ path: String) {
        let components = Keyword.components(path)
        for depth in components.indices {
            let partial = components[...depth].joined(separator: "|")
            if !contains(partial) {
                // Insert after the parent's last descendant to keep the tree grouped.
                let parent = components[..<depth].joined(separator: "|").lowercased()
                if depth > 0, let last = paths.lastIndex(where: { $0.lowercased() == parent || $0.lowercased().hasPrefix(parent + "|") }) {
                    paths.insert(partial, at: last + 1)
                } else {
                    paths.append(partial)
                }
            }
        }
    }

    /// Removes a keyword and all of its children.
    public mutating func remove(_ path: String) {
        let lower = Keyword.normalize(path).lowercased()
        paths.removeAll { $0.lowercased() == lower || $0.lowercased().hasPrefix(lower + "|") }
    }

    /// Serializes in the Lightroom/Bridge tab-indented format, sorted alphabetically within each level.
    public var text: String {
        var lines: [String] = []
        for node in tree {
            emit(node, depth: 0, into: &lines)
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    private func emit(_ node: KeywordNode, depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "\t", count: depth)
        let name = categories.contains(node.path.lowercased()) ? "[\(node.name)]" : node.name
        lines.append(indent + name)
        for synonym in synonyms[node.path] ?? [] { lines.append(indent + "\t" + synonym) }
        for child in node.children ?? [] { emit(child, depth: depth + 1, into: &lines) }
    }

    /// The keywords as a sorted tree.
    public var tree: [KeywordNode] { KeywordNode.tree(from: paths) }
}

/// A node in a keyword hierarchy.
public struct KeywordNode: Identifiable, Hashable, Sendable {
    public let name: String
    /// Full path, e.g. "Places|Iceland".
    public let path: String
    /// `nil` for leaves (convenient for SwiftUI outlines).
    public var children: [KeywordNode]?

    public var id: String { path.lowercased() }

    /// Builds a tree from keyword paths; missing parents are created.
    public static func tree(from paths: [String]) -> [KeywordNode] {
        final class Builder {
            let name: String, path: String
            var children: [String: Builder] = [:]
            init(name: String, path: String) { self.name = name; self.path = path }
            func node() -> KeywordNode {
                let kids = children.values
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    .map { $0.node() }
                return KeywordNode(name: name, path: path, children: kids.isEmpty ? nil : kids)
            }
        }
        let root = Builder(name: "", path: "")
        for path in paths {
            var current = root
            var prefix: [String] = []
            for component in Keyword.components(path) {
                prefix.append(component)
                let key = component.lowercased()
                if current.children[key] == nil {
                    current.children[key] = Builder(name: component, path: prefix.joined(separator: "|"))
                }
                current = current.children[key]!
            }
        }
        return root.node().children ?? []
    }
}
