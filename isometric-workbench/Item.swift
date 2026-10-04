//
//  Item.swift
//  isometric-workbench
//
//  Created by Fiqry Choerudin on 04/10/26.
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
