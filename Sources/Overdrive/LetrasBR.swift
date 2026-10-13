import Foundation
import WebKit

enum LetrasBR {
    nonisolated static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        var result = ""
        result.reserveCapacity(folded.count)
        var dash = true
        for scalar in folded.unicodeScalars {
            if scalar.value >= 97 && scalar.value <= 122 || scalar.value >= 48 && scalar.value <= 57 {
                result.append(Character(scalar))
                dash = false
            } else if !dash {
                result.append("-")
                dash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    nonisolated static func page(_ artist: String, _ title: String) -> URL {
        URL(string: "https://www.letras.mus.br/\(slug(artist))/\(slug(title))/")!
    }

    nonisolated static func search(_ artist: String, _ title: String) async -> URL? {
        let query = "\(title) \(artist)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://solr.sscdn.co/letras/m1/?q=\(query)&wt=json") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        var text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "("), let end = text.lastIndex(of: ")"), start < end {
            text = String(text[text.index(after: start)..<end])
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let docs = (json["response"] as? [String: Any])?["docs"] as? [[String: Any]]
        else { return nil }
        let wantArtist = slug(artist)
        let wantTitle = slug(title)
        var best: [String: Any]?
        var bestScore = -1
        for doc in docs {
            guard (doc["t"] as? String) == "2",
                let dns = doc["dns"] as? String,
                let path = doc["url"] as? String
            else { continue }
            var score = Int((doc["score"] as? Double ?? 0).rounded())
            if slug(doc["art"] as? String ?? "") == wantArtist { score += 100 }
            if slug(doc["txt"] as? String ?? "") == wantTitle { score += 100 }
            if score > bestScore {
                bestScore = score
                best = ["dns": dns, "url": path]
            }
        }
        guard let dns = best?["dns"] as? String, let path = best?["url"] as? String else { return nil }
        return URL(string: "https://www.letras.mus.br/\(dns)/\(path)/")
    }

    @MainActor static func lyrics(artist: String, title: String) async -> String {
        if let found = await search(artist, title), let text = await scrape(found), !text.isEmpty {
            return text
        }
        if let text = await scrape(page(artist, title)), !text.isEmpty {
            return text
        }
        return ""
    }

    @MainActor private static func scrape(_ url: URL) async -> String? {
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

        let delegate = Delegate()
        let web = WKWebView(frame: .zero)
        web.isHidden = true
        web.navigationDelegate = delegate
        defer {
            web.stopLoading()
            web.navigationDelegate = nil
        }
        let loaded = await withCheckedContinuation { continuation in
            delegate.done = continuation
            _ = web.load(URLRequest(url: url, timeoutInterval: 15))
            Task { @MainActor [weak delegate] in
                try? await Task.sleep(for: .seconds(15))
                delegate?.done?.resume(returning: false)
                delegate?.done = nil
            }
        }
        guard loaded else { return nil }
        let script = "(function(){var el=document.querySelector('div.lyric-original');if(!el)el=document.querySelector('div.cnt-letra');if(!el)return '';var c=el.cloneNode(true);c.querySelectorAll('script,style').forEach(function(n){n.remove()});c.querySelectorAll('br').forEach(function(b){b.replaceWith('\\n')});c.querySelectorAll('p').forEach(function(p){p.prepend('\\n');p.append('\\n')});return (c.innerText||c.textContent||'').replace(/[ \\t]+\\n/g,'\\n').replace(/\\n{3,}/g,'\\n\\n').trim();})()"
        for _ in 0..<20 {
            if let value = try? await web.evaluateJavaScript(script) as? String {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count > 20 { return text }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if let value = try? await web.evaluateJavaScript(script) as? String {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }
}
