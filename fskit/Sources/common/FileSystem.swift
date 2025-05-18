import FSKit
import Foundation

public class FileSystem {
    public init() {
        
    }
    public func createRootNode(manifestPath: String) throws -> FSItemProtocol {
        let data = try Data(contentsOf: URL(filePath: manifestPath))
        let depTree = try DependencyNode.fromJSONData(data)
        let depFsNode = DependencyFSNodeCreator().buildTree(from: depTree)
        return depFsNode
    }
    public func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes req: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    )  throws -> FSDirectoryVerifier {

        // https://developer.apple.com/documentation/fskit/fsvolume/operations/enumeratedirectory(_:startingat:verifier:attributes:packer:replyhandler:)?language=objc
        // If the attributes parameter is nil, include at least two entries in a directory: "." and "..", 
        // which represent the current and parent directories, respectively. Both of these items have type FSItemTypeDirectory. 
        // For the root directory, "." and ".." have identical contents. Don’t pack "." and ".." if attributes isn’t nil.

        guard let directory = directory as? FSItemProtocol else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }
        // let attributes = req?.printRequestedAttributes ?? ""

        var idx = 0
        for (name, item) in try directory.getChildren() {
            if idx < cookie {
                idx += 1
                continue
            }

            let attributes = req != nil ? try item.getAttributes() : nil  //todo requested attributes?
            let ok = packer.packEntry(
                name: name,
                itemType: item.itemType,
                itemID: item.fileId,
                nextCookie: FSDirectoryCookie(UInt64(idx + 1)),
                attributes: attributes,
            )

            if !ok {
                // fskit dont't want to continue
                break
            }
            idx += 1
        }

        return FSDirectoryVerifier(0)  //todo change 0 for mutations
    }
}
