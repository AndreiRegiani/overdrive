import Foundation

enum MetalKingdom {
    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func strip(_ html: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: "<[^>]+>") else { return html }
        return pattern.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")
    }

    nonisolated static func clean(_ html: String) -> String {
        strip(html.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n").replacingOccurrences(of: "<br />", with: "\n"))
            .replacingOccurrences(of: "[ \t]+\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func get(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func band(_ html: String, artist: String) -> URL? {
        guard let pattern = try? NSRegularExpression(pattern: "<a href=\"(/band/[^\"]+)\">\\s*<strong>([^<]+)</strong>", options: .caseInsensitive) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for match in pattern.matches(in: html, range: range) {
            guard let pathRange = Range(match.range(at: 1), in: html),
                let nameRange = Range(match.range(at: 2), in: html),
                fold(String(html[nameRange])) == fold(artist)
            else { continue }
            return URL(string: "https://www.metalkingdom.net\(html[pathRange])")
        }
        return nil
    }

    nonisolated static func albums(_ html: String, artist: String) -> [URL] {
        let prefix = "/album/" + fold(artist).replacingOccurrences(of: " ", with: "-") + "-"
        guard let pattern = try? NSRegularExpression(pattern: "\"(/album/[a-z0-9-]+)\"", options: .caseInsensitive) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var found: [URL] = []
        for match in pattern.matches(in: html, range: range) {
            guard let pathRange = Range(match.range(at: 1), in: html) else { continue }
            let slug = String(html[pathRange])
            guard slug.hasPrefix(prefix) else { continue }
            let path = slug.replacingOccurrences(of: "/album/", with: "/lyrics-album/")
            guard let url = URL(string: "https://www.metalkingdom.net\(path)"), !found.contains(url) else { continue }
            found.append(url)
            if found.count == 10 { break }
        }
        return found
    }

    nonisolated static func songs(_ html: String, title: String) -> [URL] {
        guard let pattern = try? NSRegularExpression(pattern: "<a href=\"(/lyrics-song/[a-z0-9-]+)\"[^>]*>.*?<span itemprop=\"name\">([^<]+)</span>", options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var exact: [URL] = []
        var prefixed: [URL] = []
        for match in pattern.matches(in: html, range: range) {
            guard let pathRange = Range(match.range(at: 1), in: html),
                let nameRange = Range(match.range(at: 2), in: html),
                let url = URL(string: "https://www.metalkingdom.net\(html[pathRange])")
            else { continue }
            let name = fold(String(html[nameRange]))
            if name == fold(title) {
                if !exact.contains(url) { exact.append(url) }
            } else if name.hasPrefix(fold(title) + " ") {
                if !prefixed.contains(url) { prefixed.append(url) }
            }
        }
        return Array((exact + prefixed).prefix(2))
    }

    nonisolated static func text(_ html: String) -> String {
        guard let start = html.range(of: "<div itemprop=\"text\">"),
            let end = html.range(of: "</div>", range: start.upperBound..<html.endIndex)
        else { return "" }
        return clean(String(html[start.upperBound..<end.lowerBound]))
    }

    nonisolated static func lyrics(artist: String, title: String) async -> String {
        var components = URLComponents(string: "https://www.metalkingdom.net/band/search.php")
        components?.queryItems = [
            URLQueryItem(name: "s_mode", value: "band"),
            URLQueryItem(name: "sz_memo", value: artist),
        ]
        guard let url = components?.url,
            let page = await get(url),
            let profile = band(page, artist: artist),
            let discography = await get(profile)
        else { return "" }
        for album in albums(discography, artist: artist) {
            guard let listing = await get(album) else { continue }
            for song in songs(listing, title: title) {
                guard let page = await get(song) else { continue }
                let lyrics = text(page)
                if !lyrics.isEmpty { return lyrics }
            }
        }
        return ""
    }
}
