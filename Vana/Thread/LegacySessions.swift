import Foundation

/// 旧的「一个会话一个文件」的存储,上线新线程存储时**整个清掉,不迁移**。
///
/// 和 Android 那边同一个决定(用户在 2026-09-29 确认过):旧对话不带过去。这省掉了迁移、
/// 校验和回退路径,代价是升级的用户看不到旧对话——发版说明里要写。记忆、用药不在这里动,
/// 它们没有换存储。
///
/// 旧会话引用的照片一并清掉:它们只被旧会话引用,留着就是永远删不掉的孤儿。用一个标记文件
/// 记住「清过了」,只清一次;全新安装没有旧目录,照样写标记。
enum LegacySessions {
    @discardableResult
    static func clearIfNeeded(root: URL) -> Bool {
        let manager = FileManager.default
        let thread = root.appending(path: "thread", directoryHint: .isDirectory)
        let marker = thread.appending(path: ThreadStore.legacyMarker)
        guard !manager.fileExists(atPath: marker.path(percentEncoded: false)) else { return false }
        try? manager.removeItem(at: root.appending(path: "sessions", directoryHint: .isDirectory))
        try? manager.removeItem(at: root.appending(path: "attachments", directoryHint: .isDirectory))
        try? manager.createDirectory(at: thread, withIntermediateDirectories: true)
        manager.createFile(
            atPath: marker.path(percentEncoded: false),
            contents: Data("旧的会话存储已在新线程存储上线时清除，不迁移。".utf8)
        )
        return true
    }
}
