import FSKit
import Foundation

public class FileSystem: FSVolume {
    
    public func createRootNode(manifestPath: String) throws -> FSItemProtocol {
        let data = try Data(contentsOf: URL(filePath: manifestPath))
        let depTree = try DependencyNode.fromJSONData(data)
        let depFsNode = DependencyFSNodeCreator().buildTree(from: depTree)
        return depFsNode
    }
    @objc(enumerateDirectory:startingAtCookie:verifier:providingAttributes:usingPacker:replyHandler:) public func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes req: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) async throws -> FSDirectoryVerifier {

        // https://developer.apple.com/documentation/fskit/fsvolume/operations/enumeratedirectory(_:startingat:verifier:attributes:packer:replyhandler:)?language=objc
        // If the attributes parameter is nil, include at least two entries in a directory: "." and "..",
        // which represent the current and parent directories, respectively. Both of these items have type FSItemTypeDirectory.
        // For the root directory, "." and ".." have identical contents. Don’t pack "." and ".." if attributes isn’t nil.

        let version = UInt64(0) //todo
        
        guard let directory = directory as? FSItemProtocol else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }

        if cookie.rawValue < 1 {
            guard
                packer.packEntry(
                    name: FSFileName(string: "."), itemType: .directory, itemID: directory.fileId,
                    nextCookie: FSDirectoryCookie(1), attributes: try directory.getAttributes()) //todo
            else {
                return FSDirectoryVerifier(version)
            }

        }

        if cookie.rawValue < 2 {
            guard
                packer.packEntry(
                    name: FSFileName(string: ".."), itemType: .directory,
                    itemID: directory.parentId, nextCookie: FSDirectoryCookie(2),
                    attributes: try directory.getAttributes() //todo
                )
            else {
                return FSDirectoryVerifier(version)
            }
        }
        var currentOffset = 2


        for (name, item) in try directory.getChildren() {
            if currentOffset < cookie.rawValue {
                currentOffset += 1
                continue
            }

            let attributes = req != nil ? try item.getAttributes() : nil  //todo requested attributes?
            let ok = packer.packEntry(
                name: name,
                itemType: item.itemType,
                itemID: item.fileId,
                nextCookie: FSDirectoryCookie(UInt64(currentOffset + 1)),
                attributes: attributes,
            )

            if !ok {
                // fskit dont't want to continue
                break
            }
            currentOffset += 1
        }

        return FSDirectoryVerifier(version)
    }
}

