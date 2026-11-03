import Foundation

/// 基于 DispatchSource 的文件 / 目录监控：零空闲开销，无轮询。
/// 原子写入（编辑器保存）会触发 rename/delete，此时自动重新打开 fd 继续监控。
public final class FileWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable () -> Void

    private let url: URL
    private let queue: DispatchQueue
    private let handler: Handler
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounce: DispatchWorkItem?
    private let debounceInterval: TimeInterval
    private let lock = NSLock()

    /// - Parameters:
    ///   - url: 文件或目录
    ///   - debounce: 合并短时间内的多次事件（编辑器保存通常触发 2–3 次）
    ///   - queue: 回调队列（默认后台）
    public init(url: URL, debounce: TimeInterval = 0.15, queue: DispatchQueue = DispatchQueue(label: "com.korako.quire.filewatcher", qos: .utility), handler: @escaping Handler) {
        self.url = url
        self.queue = queue
        self.handler = handler
        self.debounceInterval = debounce
        start()
    }

    deinit {
        stop()
        debounce?.cancel()   // 放掉就不再回调。这一句不放进 stop：重新打开也走 stop，那时排着的通知还要发
    }

    private var retryCount = 0

    private func start() {
        lock.lock(); defer { lock.unlock() }
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // 文件暂时不在（编辑器"先删再写"、或被移走后又放回来）：退避重试，别就此永远不监视了
            guard retryCount < 10 else { return }
            retryCount += 1
            let delay = min(8, 0.5 * Double(1 << min(retryCount, 4)))
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.fd < 0 else { return }   // 可能同时有几路在重试：已经打开了就别再开，那个 source 和 fd 就再也关不掉了
                self.start()
                if self.fd >= 0 { self.fire() }   // 回来了：内容大概率变了
            }
            return
        }
        retryCount = 0
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            self.fire()
            if flags.contains(.rename) || flags.contains(.delete) { self.reopenSoon() }
        }
        // kqueue 在 resume 之后才异步注册：这之前文件又被替换的话事件已经错过，fd 留在没人用的 inode 上，之后什么都收不到。注册完对一次路径
        src.setRegistrationHandler { [weak self, fd] in
            guard let self, !self.pathStillRefers(to: fd) else { return }
            self.reopenSoon()
        }
        src.setCancelHandler { [fd] in if fd >= 0 { close(fd) } }
        source = src
        src.resume()
    }

    /// 文件被替换：稍后重新打开（新文件可能还没落盘）。这段时间旧 fd 看不到新文件，上一次通知读到的可能已经不是最新的（连续存储、切分支），所以打开之后再报一次
    private func reopenSoon() {
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.stop(); self.start()
            if self.fd >= 0 { self.fire() }
        }
    }

    /// fd 打开的还是不是路径上现在这个文件（路径不在了也算不是）
    private func pathStillRefers(to fd: Int32) -> Bool {
        var opened = stat(), now = stat()
        return fstat(fd, &opened) == 0 && stat(url.path, &now) == 0 && opened.st_ino == now.st_ino && opened.st_dev == now.st_dev
    }

    private func stop() {
        lock.lock(); defer { lock.unlock() }
        source?.cancel()
        source = nil
        fd = -1
    }

    private func fire() {
        debounce?.cancel()
        let item = DispatchWorkItem { [handler] in handler() }
        debounce = item
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }
}
