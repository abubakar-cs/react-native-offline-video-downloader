//
//  BackgroundSessionHandler.swift
//  Pods
//
//  Created by EtvWin on 24/11/25.
//

import Foundation

class CompletionHandlerWrapper: NSObject {
    let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }
}
