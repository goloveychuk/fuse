//
//  MyFSItem.swift
//  FSKitExp
//
//  Created by Khaos Tian on 3/30/25.
//

import Foundation
import FSKit

final class AtomicInt {
    private var value: Int64
    
    init(_ initialValue: Int64) {
        value = initialValue
    }
    
    func increment() -> Int64 {
        return OSAtomicIncrement64(&value)
    }
    
    // func getValue() -> Int64 {
    //     return OSAtomicAdd64(0, &value)
    // }
}
