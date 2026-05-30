import Testing
import Foundation
@testable import MacStatsCore

@Suite struct DiskUtilsTests {
    @Test func sumsRegularFileSizes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstats-disk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hello".utf8).write(to: dir.appendingPathComponent("a.txt"))   // 5 bytes
        try Data("12345".utf8).write(to: dir.appendingPathComponent("b.txt"))   // 5 bytes
        #expect(directorySize(at: dir) == 10)
    }
    @Test func emptyDirectoryIsZero() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstats-disk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(directorySize(at: dir) == 0)
    }
    @Test func missingDirectoryIsZero() {
        let dir = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(directorySize(at: dir) == 0)
    }
}
