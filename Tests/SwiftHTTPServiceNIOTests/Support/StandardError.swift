import Foundation
import Testing

/// Runs `body` with standard error redirected to a file, and returns what was written to it.
func captureStandardError(_ body: () async throws -> Void) async throws -> String {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("stderr-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: file.path, contents: nil) else { return "(could not capture)" }
    defer { do { try FileManager.default.removeItem(at: file) } catch { Issue.record("could not remove \(file.path)") } }
    let handle = try FileHandle(forWritingTo: file)
    let saved = dup(STDERR_FILENO)
    fflush(nil)
    dup2(handle.fileDescriptor, STDERR_FILENO)
    defer { dup2(saved, STDERR_FILENO); close(saved) }
    try await body()
    fflush(nil)
    try handle.close()
    return String(decoding: try Data(contentsOf: file), as: UTF8.self)
}
