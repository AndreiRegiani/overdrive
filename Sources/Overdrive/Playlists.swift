import Foundation

@Observable
final class Playlists {
    static let directory = URL.homeDirectory.appending(path: "Music/Library/Playlists", directoryHint: .isDirectory)

    private(set) var names: [String] = []
    private(set) var paths: [String: [String]] = [:]
    var naming: [URL]?

    init() {
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []

        paths = [:]

        for file in files where file.pathExtension == "playlist" {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            paths[file.deletingPathExtension().lastPathComponent] = text.split(whereSeparator: \.isNewline).map(String.init)
        }

        names = paths.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func valid(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)

        return !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":")
            && !names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    @discardableResult
    func create(_ name: String, _ urls: [URL]) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard valid(name) else { return nil }

        names.append(name)
        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        add(urls, to: name)

        return name
    }

    func add(_ urls: [URL], to name: String) {
        var list = paths[name] ?? []
        var seen = Set(list)

        for url in urls where seen.insert(url.path).inserted {
            list.append(url.path)
        }

        save(name, list)
    }

    func remove(_ urls: Set<URL>, from name: String) {
        let removed = Set(urls.map(\.path))

        save(name, (paths[name] ?? []).filter { !removed.contains($0) })
    }

    func delete(_ name: String) {
        try? FileManager.default.trashItem(at: file(name), resultingItemURL: nil)

        paths[name] = nil
        names.removeAll { $0 == name }
    }

    private func save(_ name: String, _ list: [String]) {
        paths[name] = list

        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? Data(list.map { $0 + "\n" }.joined().utf8).write(to: file(name), options: .atomic)
    }

    private func file(_ name: String) -> URL {
        Self.directory.appending(path: name + ".playlist", directoryHint: .notDirectory)
    }
}
