//
//  FSKitExpExtension.swift
//  FSKitExpExtension
//
//  Created by Khaos Tian on 3/30/25.
//

import Foundation
import FSKit

@main
@available(macOS 15.4, *)
struct FSKitExpExtension : UnaryFileSystemExtension {
    
    var fileSystem : FSUnaryFileSystem & FSUnaryFileSystemOperations {
        MyFS()
    }
}
