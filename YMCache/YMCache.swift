//
//  YMCache.swift
//  YMCache
//
//  Created by Adam Kaplan on 8/14/15.
//  Copyright (c) 2015 Yahoo, Inc. All rights reserved.
//

import Foundation

public class YMMemoryCacheSwift<Key: Hashable, Val> : NSObject {
    
    typealias EvictionDeciderType = (key: Key, val: Val) -> Bool
    
    let name: String?
    
    let evictionDecider: EvictionDeciderType?
    
    var evictionInterval: UInt64 = 0 {
        didSet {
            // Exit early if no eviction queue, which means this is not an evicting memory cache
            guard let evictionQueue = evictionQueue else {
                return;
            }
            
            dispatch_async(evictionQueue) {
                if let oldTimer = self.evictionTimer {
                    dispatch_source_cancel(oldTimer)
                    self.evictionTimer = nil
                }

                if self.evictionInterval == 0 {
                    return
                }
                
                let timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, evictionQueue)
                
                self.evictionTimer = timer
                
                dispatch_source_set_event_handler(timer, {[weak self] () -> Void in
                    self?.purgeEvictableItems()
                })
                
                dispatch_source_set_timer(timer,
                    dispatch_time(DISPATCH_TIME_NOW, (Int64)(self.evictionInterval * NSEC_PER_SEC)),
                    self.evictionInterval * NSEC_PER_SEC,
                    5 * NSEC_PER_MSEC)
                
                dispatch_resume(timer)
            }
        }
    }

    private func _updateAfterNotificationIntervalChanged() {
        if let oldTimer = self.notificationTimer {
            dispatch_source_cancel(oldTimer)
            self.notificationTimer = nil
        }
        
        // Reset any pending notifications since they might be invalid for
        // notification based on the new interval
        self.pendingNotify = [Key: Val]()
        
        if self.notificationInterval == 0 {
            return
        }
        
        let timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
            0, 0, self.queue)
        self.notificationTimer = timer;
        
        dispatch_source_set_event_handler(timer, {[weak self] () -> Void in
            self?.sendPendingNotifications()
            })
        
        dispatch_source_set_timer(timer,
            dispatch_time(DISPATCH_TIME_NOW, (Int64)(self.notificationInterval * NSEC_PER_SEC)),
            self.notificationInterval * NSEC_PER_SEC,
            5 * NSEC_PER_SEC)
        
        dispatch_resume(timer)
    }
    
    var notificationInterval: UInt64 = 0 {
        didSet {
            write { $0._updateAfterNotificationIntervalChanged() }
        }
    }
    
    var allItems: Dictionary<Key, Val> {
        get {
            return read ({ $0.items })!
        }
    }
    
    init(cacheName: String?, evictionDecider: EvictionDeciderType? = nil) {
        name = cacheName
        
        // Initialize reader-writer queue
        
        var queueId = "com.yahoo.cache"
        if let queueSuffix = name {
            queueId += " \(queueSuffix)"
        }
        
        self.queue = dispatch_queue_create(queueId.cStringUsingEncoding(NSUTF8StringEncoding)!,
            DISPATCH_QUEUE_CONCURRENT)
        
        // Initialize eviction system, if needed
        
        self.evictionDecider = evictionDecider
        if evictionDecider != nil {
            let evictionQueueId = queueId + ".eviction"
            
            self.evictionQueue = dispatch_queue_create(evictionQueueId.cStringUsingEncoding(NSUTF8StringEncoding)!,
                DISPATCH_QUEUE_SERIAL)
            
            self.evictionInterval = 600
        }
        else {
            self.evictionQueue = nil
        }
    }

    deinit {
        if let timer = self.evictionTimer {
            if  0 == dispatch_source_testcancel(timer) {
                dispatch_source_cancel(timer)
            }
        }
        
        if let timer = self.notificationTimer {
            if  0 == dispatch_source_testcancel(timer) {
                dispatch_source_cancel(timer)
            }
        }
    }
    
    convenience override init() {
        self.init(cacheName: nil, evictionDecider: nil)
    }
    
    func write(block:(YMMemoryCacheSwift) -> () ) {
        dispatch_barrier_async(self.queue) {[weak self] in
            guard let it = self else {
                return
            }
            block(it)
        }
    }
    
    func read<T>(block:(YMMemoryCacheSwift)->(T?)) -> T? {
        var ret : T?
        dispatch_sync(queue) { () -> Void in
            ret = block(self)
        }
        return ret
    }
    
    subscript(key: Key) -> Val? {
        // Synchronous (but parallel)
        get {
            return read { $0[key] }
        }
        
        // Concurrent (but not parallel)
        set(newVal) {
            write {
                $0.items[key] = newVal
                $0.pendingNotify[key] = newVal
            }
        }
    }
    
    func addEntriesFromDictionary(dict: Dictionary<Key, Val>) {
        write {
            for (key,val) in dict {
                $0.items[key] = val
                $0.pendingNotify[key] = val
            }
        }
    }
    
    func removeAll() {
        write {
            $0.items.removeAll()
            $0.pendingNotify.removeAll()
        }
    }
    
    func removeObjectsForKeys(keys: [Key]) {
        guard keys.isEmpty == false else {
            return
        }
        write {
            for key in keys {
                $0.items.removeValueForKey(key)
                $0.pendingNotify.removeValueForKey(key)
            }
        }
    }
    
    // Notifications
    
    func sendPendingNotifications() {
        // Assert private queue only
        
        guard self.pendingNotify.isEmpty == true else {
            return
        }
        
        dispatch_async(dispatch_get_main_queue()) {
            let nc = NSNotificationCenter.defaultCenter()
            //nc.postNotificationName(kYFCacheItemsChangedNotificationKey, object: self, userInfo: pending)
            nc.postNotificationName(kYFCacheItemsChangedNotificationKey, object: self, userInfo: nil)
        }
    }
    
    // Eviction
    
    func purgeEvictableItems() {
        guard let evictionDecider = self.evictionDecider else {
            return
        }
        
        let keysToEvict = self.allItems
            .filter { evictionDecider(key: $0, val: $1) }
            .map { return $0.0 }
        
        self.removeObjectsForKeys(keysToEvict)
    }
    
    // Private
    
    private var items = [Key: Val]()
    private var pendingNotify = [Key: Val]()
    private let queue: dispatch_queue_t
    private let evictionQueue: dispatch_queue_t?
    private var evictionTimer: dispatch_source_t?
    private var notificationTimer: dispatch_source_t?
    
}
