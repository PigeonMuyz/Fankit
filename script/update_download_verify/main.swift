import Foundation

final class Samples: @unchecked Sendable {
    let lock = NSLock()
    var values: [(Int64, Int64)] = []
    func add(_ received: Int64, _ total: Int64) {
        lock.lock()
        defer { lock.unlock() }
        values.append((received, total))
    }
    func snapshot() -> [(Int64, Int64)] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@main
struct Verify {
    static func main() async throws {
        let port = CommandLine.arguments[1]
        for path in ["known", "unknown"] {
            let samples = Samples()
            let (file, _) = try await UpdateDownloadDelegate.download(
                from: URL(string: "http://127.0.0.1:\(port)/\(path)")!) { samples.add($0, $1) }
            defer { try? FileManager.default.removeItem(at: file) }
            let data = try Data(contentsOf: file)
            precondition(data.count == 512 * 1024)
            let values = samples.snapshot()
            precondition(values.contains { $0.0 > 0 && $0.0 < 512 * 1024 })
            precondition(values.last?.0 == 512 * 1024)
            if path == "known" {
                precondition(values.allSatisfy { $0.1 == 512 * 1024 })
            } else {
                precondition(values.allSatisfy { $0.1 <= 0 })
            }
            print("\(path): \(values.count) progress callbacks, complete file verified")
        }
    }
}
