//
//  Local.swift
//  KZFileWatchers
//
//  Created by Krzysztof Zabłocki on 05/08/16.
//
//

import Foundation

public extension FileWatcher {

    /**
     Watcher for local files, it uses content diffing.
     */
    public final class Local: FileWatcherProtocol {
        fileprivate typealias CancelBlock = () -> Void

        fileprivate enum State {
            case started(source: DispatchSource, fileHandle: CInt, callback: FileWatcher.UpdateClosure, cancel: CancelBlock)
            case stopped
        }

        fileprivate let path: String
        fileprivate let refreshInterval: TimeInterval
        fileprivate let queue: DispatchQueue

        fileprivate var state: State = .stopped
        fileprivate var isProcessing: Bool = false
        fileprivate var cancelReload: CancelBlock?
        fileprivate var previousContent: Data?

        /**
         Initializes watcher to specified path.

         - parameter path:     Path of file to observe.
         - parameter refreshInterval: Refresh interval to use for updates.
         - parameter queue:    Queue to use for firing `onChange` callback.

         - note: By default it throttles to 60 FPS, some editors can generate stupid multiple saves that mess with file system e.g. Sublime with AutoSave plugin is a mess and generates different file sizes, this will limit wasted time trying to load faster than 60 FPS, and no one should even notice it's throttled.
         */
        public init(path: String, refreshInterval: TimeInterval = 1/60, queue: DispatchQueue = DispatchQueue.main) {
            self.path = path
            self.refreshInterval = refreshInterval
            self.queue = queue
        }

        /**
         Starts observing file changes.

         - throws: FileWatcher.Error
         */
        public func start(_ closure: FileWatcher.UpdateClosure) throws {
            guard case .stopped = state else { throw FWError.alreadyStarted }
            try startObserving(closure)
        }

        /**
         Stops observing file changes.
         */
        public func stop() throws {
            guard case let .started(_, _, _, cancel) = state else { throw FWError.alreadyStopped }
            cancelReload?()
            cancelReload = nil
            cancel()

            isProcessing = false
            state = .stopped
        }

        deinit {
            if case .started = state {
                _ = try? stop()
            }
        }

        fileprivate func startObserving(_ closure: FileWatcher.UpdateClosure) throws {
            let handle = open(path, O_EVTONLY)

            if handle == -1 {
                throw FWError.failedToStart(reason: "Failed to open file")
            }

            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: handle, eventMask: [DispatchSource.FileSystemEvent.delete, DispatchSource.FileSystemEvent.write, DispatchSource.FileSystemEvent.extend, DispatchSource.FileSystemEvent.attrib, DispatchSource.FileSystemEvent.link, DispatchSource.FileSystemEvent.rename, DispatchSource.FileSystemEvent.revoke], queue: queue)

            let cancelBlock = {
                source.cancel()
            }

            source.setEventHandler {
                let flags = source.data

                if flags.contains(DispatchSource.FileSystemEvent.delete) ||
                    flags.contains(DispatchSource.FileSystemEvent.rename) {
                    _ = try? self.stop()
                    _ = try? self.startObserving(closure)
                    return
                }

                self.needsToReload()
            }

            source.setCancelHandler {
                close(handle)
            }

            source.resume()

            state = .started(source: source as! DispatchSource, fileHandle: handle, callback: closure, cancel: cancelBlock)
            refresh()
        }

        fileprivate func needsToReload() {
            guard case .started = state else { return }

            cancelReload?()
            cancelReload = throttle(after: refreshInterval) { self.refresh() }
        }

        /**
         Force refresh, can only be used if the watcher was started and it's not processing.
         */
        public func refresh() {
            guard case let .started(_, _, closure, _) = state , isProcessing == false else { return }
            isProcessing = true

            guard let content = try? Data(contentsOf: URL(fileURLWithPath: path), options: .uncached) else {
                isProcessing = false
                return
            }

            if content != previousContent {
                previousContent = content
                queue.async {
                    closure(.updated(data: content))
                }
            } else {
                queue.async {
                    closure(.noChanges)
                }
            }

            isProcessing = false
            cancelReload = nil
        }

        fileprivate func throttle(after: Double, action: @escaping () -> Void) -> CancelBlock {
            var isCancelled = false
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + Double(Int64(after * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)) {
                if !isCancelled {
                    action()
                }
            }

            return {
                isCancelled = true
            }
        }
    }

}


public extension FileWatcher.Local {
    #if (arch(i386) || arch(x86_64)) && os(iOS)

    /**
     Returns username of OSX machine when running on simulator.

     - returns: Username (if available)
     */
    public class func simulatorOwnerUsername() -> String {
        //! running on simulator so just grab the name from home dir /Users/{username}/Library...
        let usernameComponents = NSHomeDirectory().components(separatedBy: "/")
        guard usernameComponents.count > 2 else { fatalError() }
        return usernameComponents[2]
    }
    #endif
}
