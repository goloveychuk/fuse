//
//  FSKitExpExtension.swift
//  FSKitExpExtension
//
//  Created by Khaos Tian on 3/30/25.
//

import FSKit
import Foundation

extension FSItem.GetAttributesRequest {
    convenience init(_ wantedAttributes: FSItem.Attribute) {
        self.init()
        self.wantedAttributes = wantedAttributes
    }
}

extension FSMutableFileDataBuffer: MutableBufferLike {
}

enum Constants {

    static let containerIdentifier: UUID = UUID(uuidString: "8E055EB2-12FD-4EB8-A315-C082CBCFBDD3")!
    static let volumeIdentifier: UUID = UUID(uuidString: "CDCB994E-677C-482B-B1D2-E7BC1E07546E")!
}

@main
@available(macOS 15.4, *)
struct FSKitExpExtension: UnaryFileSystemExtension {

    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        MyFS()
    }
}

final class MyFS: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    private let logger = Logger(subsystem: "FSKitExp", category: "MyFS")

    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        logger.debug("probeResource: \(resource, privacy: .public)")

        replyHandler(
            FSProbeResult.usable(
                name: "Test1",
                containerID: FSContainerIdentifier(uuid: Constants.containerIdentifier)
            ),
            nil
        )
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        containerStatus = .ready
        logger.debug("loadResource: \(resource, privacy: .public)")
        replyHandler(
            MyFSVolume(resource: resource),
            nil
        )
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        logger.debug("unloadResource: \(resource, privacy: .public)")
        reply(nil)
    }

    func didFinishLoading() {
        logger.debug("didFinishLoading")
    }
}
