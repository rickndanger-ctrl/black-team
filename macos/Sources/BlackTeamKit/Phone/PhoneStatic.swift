import Foundation

/// The built web app (`dist/`), served to the phone. Files are found inside the folder only: no `..`, no
/// backslash or NUL, and a symbolic link that leads outside is not followed (server.cjs, end of `handler`).
struct PhoneStaticFiles: Sendable {
    let folder: String

    private static let contentTypes = [
        ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
        ".json": "application/json", ".webmanifest": "application/manifest+json", ".png": "image/png", ".svg": "image/svg+xml",
        ".woff2": "font/woff2", ".txt": "text/plain; charset=utf-8",
    ]
    private static let largest = 64 * 1024 * 1024

    func response(for path: String) throws -> HTTPResponse {
        guard var relative = path.removingPercentEncoding else { throw HTTPFailure("Invalid path.") }
        if relative == "/" || relative == "/index.html" { relative = "/index.html" }
        if relative.contains("\0") || relative.contains("\\") || relative.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
            throw HTTPFailure("Invalid path.")
        }
        let missing = HTTPFailure("Not found.", 404)
        guard let rootPointer = realpath(folder, nil) else { throw missing }
        let root = String(cString: rootPointer); free(rootPointer)
        // Empty and "." parts are dropped, as path.resolve does.
        let parts = relative.split(separator: "/").filter { $0 != "." }
        let candidate = ([root] + parts.map(String.init)).joined(separator: "/")
        guard candidate.hasPrefix(root + "/"), let realPointer = realpath(candidate, nil) else { throw missing }
        let real = String(cString: realPointer); free(realPointer)
        let info = CoreFS.stat(real)
        guard real.hasPrefix(root + "/"), info.error == 0, (info.mode & S_IFMT) == S_IFREG, info.size <= Self.largest,
              let content = FileManager.default.contents(atPath: real) else { throw missing }
        var response = HTTPResponse(status: 200, body: content)
        response.set("Content-Type", Self.contentTypes[("." + (real as NSString).pathExtension)] ?? "application/octet-stream")
        if relative == "/sw.js" { response.set("Service-Worker-Allowed", "/") }
        return response
    }
}
