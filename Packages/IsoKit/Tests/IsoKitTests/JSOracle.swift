import Foundation
import IsoGeometry
import JavaScriptCore

/// Runs the Figma plugin's `code.js` in JavaScriptCore with a do-nothing
/// `figma` stub, so tests can compare the Swift port against the original.
final class JSOracle: @unchecked Sendable {
    static let shared = JSOracle()

    private let context: JSContext
    private let lock = NSLock()

    private init() {
        let url = Bundle.module.url(forResource: "code", withExtension: "js", subdirectory: "Fixtures")!
        let source = try! String(contentsOf: url, encoding: .utf8)
        context = JSContext()!
        context.exceptionHandler = { _, exception in
            print("JS exception:", exception?.toString() ?? "?")
        }
        context.evaluateScript(
            """
            var figma = {
              showUI() {}, notify() {}, commitUndo() {}, on() {},
              ui: { postMessage() {} },
              currentPage: { selection: [] },
              clientStorage: { getAsync: () => Promise.resolve(null), setAsync: () => Promise.resolve() },
            };
            var __html__ = "";
            var module = { exports: {} };
            """)
        context.evaluateScript(source)
        context.evaluateScript("var E = module.exports;")
    }

    /// Evaluates a JS expression and returns its JSON value.
    func json(_ expression: String) throws -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        guard let s = context.evaluateScript("JSON.stringify(\(expression))")?.toString(), s != "undefined" else {
            throw OracleError.noValue(expression)
        }
        return try JSONValue.parse(s)
    }

    enum OracleError: Error { case noValue(String) }
}

extension Op {
    var jsLiteral: String { json.jsonString }
}

extension Array where Element == Op {
    var jsLiteral: String { JSONValue.array(map(\.json)).jsonString }
}
