import Foundation
import WebKit

enum MetalArchives {
    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func strip(_ html: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: "<[^>]+>") else { return html }
        return pattern.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func songID(_ cell: String) -> String? {
        guard let pattern = try? NSRegularExpression(pattern: "lyricsLink_(\\d+)"),
            let match = pattern.firstMatch(in: cell, range: NSRange(cell.startIndex..., in: cell)),
            let range = Range(match.range(at: 1), in: cell)
        else { return nil }
        return String(cell[range])
    }

    nonisolated static func searchURL(artist: String, title: String) -> URL? {
        var components = URLComponents(string: "https://www.metal-archives.com/search/ajax-advanced/searching/songs/")
        components?.queryItems = [
            URLQueryItem(name: "bandName", value: artist),
            URLQueryItem(name: "songTitle", value: title),
        ]
        return components?.url
    }

    nonisolated static func candidates(_ json: String, artist: String, title: String) -> [String] {
        guard let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = root["aaData"] as? [[Any]]
        else { return [] }
        var exact: [(id: String, full: Bool)] = []
        var other: [(id: String, full: Bool)] = []
        for row in rows {
            guard row.count >= 5,
                let band = row[0] as? String,
                let type = row[2] as? String,
                let song = row[3] as? String,
                let cell = row[4] as? String,
                let id = songID(cell)
            else { continue }
            let full = strip(type).contains("Full-length")
            if fold(strip(band)) == fold(artist), fold(song) == fold(title) {
                exact.append((id, full))
            } else {
                other.append((id, full))
            }
        }
        let rank = { (list: [(id: String, full: Bool)]) in list.sorted { $0.full && !$1.full }.map(\.id) }
        let ids = rank(exact)
        return ids.isEmpty ? Array(rank(other).prefix(3)) : Array(ids.prefix(4))
    }

    @MainActor static func lyrics(artist: String, title: String) async -> String {
        final class Delegate: NSObject, WKNavigationDelegate, @unchecked Sendable {
            var done: CheckedContinuation<Bool, Never>?
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                done?.resume(returning: true)
                done = nil
            }
            func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
                done?.resume(returning: false)
                done = nil
            }
            func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
                done?.resume(returning: false)
                done = nil
            }
        }

        func load(_ web: WKWebView, _ url: URL) async -> Bool {
            let delegate = Delegate()
            web.navigationDelegate = delegate
            return await withCheckedContinuation { continuation in
                delegate.done = continuation
                _ = web.load(URLRequest(url: url, timeoutInterval: 15))
                Task { @MainActor [weak delegate] in
                    try? await Task.sleep(for: .seconds(15))
                    delegate?.done?.resume(returning: false)
                    delegate?.done = nil
                }
            }
        }

        func text(_ web: WKWebView) async -> String {
            (try? await web.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String) ?? ""
        }

        func challenged(_ body: String) -> Bool {
            body.contains("security verification") || body.contains("Just a moment")
        }

        guard let search = searchURL(artist: artist, title: title) else { return "" }
        let web = WKWebView(frame: .zero)
        web.isHidden = true
        defer {
            web.stopLoading()
            web.navigationDelegate = nil
        }
        guard await load(web, search) else { return "" }
        var json = ""
        for _ in 0..<14 {
            let body = await text(web)
            if body.contains("aaData") {
                json = body
                break
            }
            if !challenged(body), body.count > 20 { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard !json.isEmpty else { return "" }
        for id in candidates(json, artist: artist, title: title) {
            guard let url = URL(string: "https://www.metal-archives.com/release/ajax-view-lyrics/id/\(id)") else { continue }
            guard await load(web, url) else { continue }
            for _ in 0..<8 {
                let body = await text(web)
                if challenged(body) { break }
                let lyrics = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !lyrics.isEmpty, lyrics != "(lyrics not available)" { return lyrics }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        return ""
    }
}
