import CoreServices
import Foundation

/// Watches folder trees with FSEvents and reports the directories that changed, on the main queue.
/// Events are coalesced by FSEvents over `latency` seconds.
final class FileSystemWatcher: @unchecked Sendable {  // stream is created, used and torn down on the main queue
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable ([String]) -> Void

    init?(paths: [URL], latency: TimeInterval = 0.4, onChange: @escaping @Sendable (_ changedDirectories: [String]) -> Void) {
        self.onChange = onChange
        guard !paths.isEmpty else { return nil }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.onChange(paths)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// Normalizes a path for comparison with FSEvents output (no trailing slash, symlinks resolved).
    static func canonical(_ path: String) -> String {
        var result = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
