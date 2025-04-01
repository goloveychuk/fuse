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

final class MyFSItem: FSItem {
    
    // private static var id = AtomicInt(Int64(FSItem.Identifier.rootDirectory.rawValue + 1))
    static func getNextID() -> UInt64 {
        
        // let newID = id.increment()
        return UInt64.random(in: 1...UInt64.max)
    }
    
    let name: FSFileName
    let id = MyFSItem.getNextID()
    
    var attributes = FSItem.Attributes()
    var xattrs: [FSFileName: Data] = [:]
    var data: Data?
    
    private(set) var children: [FSFileName: MyFSItem] = [:]
    
    init(name: FSFileName) {
        self.name = name
        attributes.fileID = FSItem.Identifier(rawValue: id) ?? .invalid
        attributes.size = 0
        attributes.allocSize = 0
        attributes.flags = 0
        
        var timespec = timespec()
        timespec_get(&timespec, TIME_UTC)
        
        attributes.addedTime = timespec
        attributes.birthTime = timespec
        attributes.changeTime = timespec
        attributes.modifyTime = timespec
    }
    
    func addItem(_ item: MyFSItem) {
        children[item.name] = item
    }
    
    func removeItem(_ item: MyFSItem) {
        children[item.name] = nil
    }
}
