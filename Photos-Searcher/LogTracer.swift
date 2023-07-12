//
//  LogTracer.swift
//  Photos-Searcher
//
//  Created by tryao on 2023/7/9.
//

import Foundation

public class LogTracer {
    var date: Date;

    init() {
        date = Date()
    }

    func start() {
        date = Date()
    }

    func logWithTime(msg: String) {
        let now = Date()
        print("\(now.timeIntervalSince(date)) \(msg)")
        date = now
    }
}
