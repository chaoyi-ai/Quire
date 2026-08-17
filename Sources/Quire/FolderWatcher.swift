import Foundation
import CoreServices

/// 一个 FSEvents 流监听整棵目录树（递归），回调给出发生变化的目录。
/// 相比给每个展开的文件夹开 DispatchSource，FSEvents 只占一个内核事件流，且带合并延迟。
final class FolderWatcher: @unchecked Sendable {
    typealias Handler = @Sendable ([URL]) -> Void
    private var stream: FSEventStreamRef?
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.korako.quire.folderwatcher", qos: .utility)

    init?(url: URL, latency: TimeInterval = 0.6, handler: @escaping Handler) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self)
            var urls: [URL] = []
            urls.reserveCapacity(count)
            for i in 0..<count { if let p = arr[i] as? String { urls.append(URL(fileURLWithPath: p, isDirectory: true)) } }
            me.handler(urls)
        }
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [url.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}
