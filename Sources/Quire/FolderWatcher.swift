import Foundation
import CoreServices

/// 一个 FSEvents 流监听整棵目录树（递归），回调给出发生变化的目录。
/// 相比给每个展开的文件夹开 DispatchSource，FSEvents 只占一个内核事件流，且带合并延迟。
final class FolderWatcher: @unchecked Sendable {
    typealias Handler = @Sendable ([URL]) -> Void
    /// 流的 info 指向它，不指向 FolderWatcher：FSEventStreamStop 不等正在跑的回调，回调摸到正在析构的对象，
    /// 运行时 abort（"deallocated with non-zero retain count"）或者段错误。它活到拆完流（见 deinit）。
    private final class Target: Sendable {
        let handler: Handler
        init(_ handler: @escaping Handler) { self.handler = handler }
    }
    private var stream: FSEventStreamRef?
    private let target: Target
    private let queue = DispatchQueue(label: "com.korako.quire.folderwatcher", qos: .utility)

    init?(url: URL, latency: TimeInterval = 0.6, handler: @escaping Handler) {
        target = Target(handler)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(target).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<Target>.fromOpaque(info).takeUnretainedValue()
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
        guard let stream else { return }
        nonisolated(unsafe) let s = stream
        // 排到 queue 上拆：和回调串行，Stop 之后不会再有回调，这时才放掉 target。不同步等，析构在哪个线程都不会和回调互等。
        queue.async { [target] in
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            withExtendedLifetime(target) {}
        }
    }
}
