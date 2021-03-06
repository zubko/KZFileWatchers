//
//  Remote.swift
//  KZFileWatchers
//
//  Created by Krzysztof Zabłocki on 05/08/16.
//
//
import Foundation

// not supported temporarily, Swift 2.2 converted to Swift 3.0

public extension FileWatcher {
    
    /**
     Watcher for remote files, it supports both ETag and Last-Modified HTTP header tags.
     */
    public final class Remote: FileWatcherProtocol {
        fileprivate enum State {
            case started(sessionHandler: URLSessionHandler, timer: Timer)
            case stopped
        }
        
        fileprivate struct Constants {
            static let IfModifiedSinceKey = "If-Modified-Since"
            static let LastModifiedKey = "Last-Modified"
            static let IfNoneMatchKey = "If-None-Match"
            static let ETagKey = "Etag"
        }
        
        internal static var sessionConfiguration: URLSessionConfiguration = {
            let config = URLSessionConfiguration.default
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            return config
        }()
        
        
        /// URL that this watcher is observing.
        let url: URL
        
        /// The minimal amount of time between querying the `url` again.
        let refreshInterval: TimeInterval
        
        fileprivate var state: State = .stopped
        
        /**
         Creates a new watcher using given URL and refreshInterval.
         
         - parameter url:             URL to observe.
         - parameter refreshInterval: Minimal refresh interval between queries.
         */
        public init(url: URL, refreshInterval: TimeInterval = 1) {
            self.url = url
            self.refreshInterval = refreshInterval
        }
        
        deinit {
            _ = try? stop()
        }
        
        public func start(_ closure: FileWatcher.UpdateClosure) throws {
            guard case .stopped = state else {
                throw FileWatcher.FWError.alreadyStarted
            }
            
            let timer = Timer.scheduledTimer(timeInterval: refreshInterval, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
            state = .started(sessionHandler: URLSessionHandler(url: url, sessionConfiguration: FileWatcher.Remote.sessionConfiguration, callback: closure), timer: timer)
            
            timer.fire()
        }
        
        public func stop() throws {
            guard case let .started(_, timer) = state else { return }
            timer.invalidate()
            state = .stopped
        }
        
        /**
         Force refresh, can only be used if the watcher was started.
         
         - throws: `FileWatcher.Error.notStarted`
         */
        @objc public func refresh() throws {
            guard case let .started(handler, _) = state else { throw FWError.notStarted }
            handler.refresh()
        }
    }
}

extension FileWatcher.Remote {
    
    fileprivate final class URLSessionHandler: NSObject, URLSessionDelegate, URLSessionDownloadDelegate {
        fileprivate var task: URLSessionDownloadTask? = nil
        fileprivate var lastModified: String = ""
        fileprivate var lastETag: String = ""
        
        fileprivate let callback: FileWatcher.UpdateClosure
        fileprivate let url: URL
        fileprivate lazy var session: URLSession = {
            return URLSession(configuration: self.sessionConfiguration, delegate: self, delegateQueue: self.processingQueue)
        }()
        
        fileprivate let processingQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            return queue
        }()
        
        fileprivate let sessionConfiguration: URLSessionConfiguration
        
        init(url: URL, sessionConfiguration: URLSessionConfiguration, callback: FileWatcher.UpdateClosure) {
            self.url = url
            self.sessionConfiguration = sessionConfiguration
            self.callback = callback
            super.init()
        }
        
        deinit {
            processingQueue.cancelAllOperations()
        }
        
        func refresh() {
            processingQueue.addOperation { [weak self] in
                guard let strongSelf = self else { return }
                
                var request = URLRequest(url: strongSelf.url)
                request.setValue(strongSelf.lastModified, forHTTPHeaderField: Constants.IfModifiedSinceKey)
                request.setValue(strongSelf.lastETag, forHTTPHeaderField: Constants.IfNoneMatchKey)
            
                strongSelf.task = strongSelf.session.downloadTask(with: request)
                strongSelf.task?.resume()
            }
        }
        
        @objc func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                assertionFailure("expected NSHTTPURLResponse received \(downloadTask.response)")
                task = nil
                return
            }
            
            if response.statusCode == 304 {
                callback(.noChanges)
                task = nil
                return
            }
            
            if let modified = response.allHeaderFields[Constants.LastModifiedKey] as? String {
                lastModified = modified
            }
            
            if let etag = response.allHeaderFields[Constants.ETagKey] as? String {
                lastETag = etag
            }
            
            guard let data = try? Data(contentsOf: location) else {
                assertionFailure("can't load data from URL \(location)")
                return
            }
            
            callback(.updated(data: data))
            task = nil
        }
    }
}
