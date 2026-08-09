//
//  Item.swift
//  flux
//
//  Created by 查俊宇 on 2026/8/9.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
