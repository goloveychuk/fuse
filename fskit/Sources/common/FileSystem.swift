import FSKit
import Foundation

public class FileSystem {
    public init() {
        
    }
    public func createRootNode(manifestPath: String) throws -> FSItem {
        let data = try Data(contentsOf: URL(filePath: manifestPath))
        let depTree = try DependencyNode.fromJSONData(data)
        let depFsNode = DependencyFSNodeCreator().buildTree(from: depTree)
        return depFsNode
    }
}
