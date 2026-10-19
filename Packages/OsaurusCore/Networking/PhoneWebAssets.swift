import Foundation

/// Explicit routes only: no user-controlled filesystem paths or plugin dependency.
enum PhoneWebAssets {
    static func asset(for path: String) -> (body: Data, contentType: String)? {
        let name: String
        let type: String
        switch path {
        case "/phone", "/phone/": name = "phone-index"; type = "text/html; charset=utf-8"
        case "/phone/app.js": name = "phone-app"; type = "text/javascript; charset=utf-8"
        case "/phone/style.css": name = "phone-style"; type = "text/css; charset=utf-8"
        case "/phone/manifest.webmanifest": name = "phone-manifest"; type = "application/manifest+json"
        case "/phone/icon-192.png": name = "phone-icon-192"; type = "image/png"
        case "/phone/icon-512.png": name = "phone-icon-512"; type = "image/png"
        case "/phone/icon.svg": name = "phone-icon"; type = "image/svg+xml"
        case "/phone/sw.js": name = "phone-sw"; type = "text/javascript; charset=utf-8"
        case "/phone/capabilities": return (Data(#"{"transcription":true,"speech":false}"#.utf8), "application/json")
        default: return nil
        }
        let ext = [
            "phone-index": "html", "phone-app": "js", "phone-style": "css",
            "phone-icon-192": "png", "phone-icon-512": "png",
            "phone-manifest": "webmanifest", "phone-icon": "svg", "phone-sw": "js",
        ][name]!
        guard let url = Bundle.module.url(forResource: name, withExtension: ext),
            let body = try? Data(contentsOf: url)
        else { return nil }
        return (body, type)
    }
}
