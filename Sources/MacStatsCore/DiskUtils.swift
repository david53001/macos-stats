import Foundation

/// Total logical size (bytes) of regular files anywhere under `url`. Returns 0 if `url`
/// is missing or unreadable. Uses logical file size (`.fileSizeKey`), not allocated blocks,
/// so the value is deterministic and matches "size of the files in here".
public func directorySize(at url: URL) -> UInt64 {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
    var total: UInt64 = 0
    for case let fileURL as URL in enumerator {
        guard let values = try? fileURL.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              let size = values.fileSize else { continue }
        total += UInt64(size)
    }
    return total
}
