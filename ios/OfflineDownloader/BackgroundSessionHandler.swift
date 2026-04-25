//
//  BackgroundSessionHandler.swift
//  ChaiShots
//
//  Created by CSTECH1 on 25/04/26.
//

import Foundation

class CompletionHandlerWrapper: NSObject {
    let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }
}
