//
//  FSKitExpExtension.swift
//  FSKitExpExtension
//
//  Created by Khaos Tian on 3/30/25.
//

import FSKit
import Foundation

extension Logger {
    static let passthroughfs = Logger(subsystem: "com.apple.fskit.PassthroughFS", category: "default")
}

public func fs_errorForPOSIXError(_ err: POSIXErrorCode) -> any Error {
    return fs_errorForPOSIXError(err.rawValue)
}

func createVolumeNameFromPath(_ path: String) -> FSFileName {
    let dirName = (path as NSString).lastPathComponent
    return FSFileName(string: dirName + "_passthrough")
}

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

    var resource: FSPathURLResource?

    public override init() {
        Logger.passthroughfs.debug("\(#function): init")
    }

    /// Performs an operation to load a resource.
    /// - Parameters:
    ///   - resource: The resource to load.
    ///   - options: The options to use when loading the resource.
    ///   - replyHandler: The handler to call when load operation is complete with the volume, and any error.
    public func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let urlResource = resource as? FSPathURLResource else {
            Logger.passthroughfs.debug("\(#function): Invalid resource type")
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        // if options.url(forOption: "S") != nil {
        //     Logger.passthroughfs.error("loadResource: for option url")
        // }
        // if options.url(forOption: "-S") != nil {
        //     Logger.passthroughfs.error("loadResource: for option url2")
        // }
        // if options.url(forOption: "s") != nil {
        //     Logger.passthroughfs.error("loadResource: for option url3")
        // }

        /// Handle any options present.
        ///
        /// This Module doesn't make use of options for loading. The only option to handle
        /// is `-f`, and that is because this Module doesn't support formatting:
        ///   If the force option is present and the file system doesn't support
        ///   formatting, this method should reply with the POSIX error ENOTSUP.
        ///
        for opt in options.taskOptions {
            if opt.contains("-f") {
                return replyHandler(nil, POSIXError(.ENOTSUP))
            }
        }

        
        guard urlResource.url.startAccessingSecurityScopedResource() else {
            Logger.passthroughfs.error("\(#function): Can't start accessing security scoped resource")
            return replyHandler(nil, POSIXError(.EACCES))
        }
        
        
        // guard yarnStore!.startAccessingSecurityScopedResource() else {
        //     Logger.passthroughfs.error("\(#function): Can't start accessing security scoped yarn store")
        //     return replyHandler(nil, POSIXError(.EACCES))
        // }
        
        
        
//        guard upperDir!.startAccessingSecurityScopedResource() else {
//            Logger.passthroughfs.error("cant start accessing upper dir")
//            return replyHandler(nil, POSIXError(.EINVAL))
//        }
//        

        // Logger.passthroughfs.error("loadResource: \(options.url(forOption: "S")?.absoluteString ?? "nil")")
        self.resource = urlResource
        do {
            self.containerStatus = .ready
            return replyHandler(try MyFSVolume(manifestPath: urlResource.url.path, mutationsPath: "/tmp"), nil)
        } catch let error {
            urlResource.url.stopAccessingSecurityScopedResource()
            self.resource = nil
            return replyHandler(nil, error)
        }
    }

    ///  Performs an operation to unload a resource.
    /// - Parameters:
    ///   - resource: The resource to unload.
    ///   - options: The options to use when unloading the resource.
    ///   - replyHandler: The handler to call when unload is complete.
    public func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        guard let urlResource = resource as? FSPathURLResource else {
            Logger.passthroughfs.error("\(#function): Can't cast resource")
            return reply(POSIXError(.EINVAL))
        }
        guard let loadedResource = self.resource else {
            Logger.passthroughfs.error("\(#function): No resource was loaded")
            return reply(POSIXError(.EINVAL))
        }
        guard loadedResource.url == urlResource.url else {
            Logger.passthroughfs.error("\(#function): Invalid resource was given to unload")
            return reply(POSIXError(.EINVAL))
        }
        loadedResource.url.stopAccessingSecurityScopedResource()
        self.resource = nil
        return reply(nil)
    }

    /// Performs a probe operation on a resource.
    /// - Parameters:
    ///   - resource: The resource to probe.
    ///   - replyHandler: The handler to call when the probe operation is complete.
    public func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let urlResource = resource as? FSPathURLResource else {
            Logger.passthroughfs.debug("\(#function): Can't cast resource")
            return replyHandler(nil, POSIXError(.ENODEV))
        }

        let name            = createVolumeNameFromPath(urlResource.url.path())
        let containerUUID   = NSUUID()
        let containerIdentifier = FSContainerIdentifier(uuid: containerUUID as UUID)
        let probeResult = FSProbeResult.usable(name: name.string ?? "", containerID: containerIdentifier)
        return replyHandler(probeResult, nil)
    }

}
