import FSKit
import Foundation

typealias PathSegment = String

// Define the LinkType enum
enum LinkType: String, Decodable {
    case HARD
    case SOFT
}

// Define custom errors for dependency operations

enum MyError: Error, LocalizedError, CustomNSError {
    case badManifest(String)
    case badMountParams
    
    var errorDescription: String? {
        switch self {
        case .badManifest(let err):
            return "Bad manifest: \(err)"
        case .badMountParams:
            return "Bad mount parameters"
        }
    }
    
    // var failureReason: String? {
    //     switch self {
    //     case .badManifest(let err):
    //         return "Bad manifest: \(err)"
    //     case .badMountParams:
    //         return "Bad mount parameters"   
    //     }
    // }
    
    // CustomNSError implementation
    // static var errorDomain: String { return "FSKitExpExtension.MyError" }
    
    var errorUserInfo: [String: Any] {
        return [
            NSLocalizedDescriptionKey: errorDescription ?? "",
            NSLocalizedFailureReasonErrorKey: failureReason ?? ""
        ]
    }
}



// Typealias for zip information
typealias ZipPathInfo = (zipPath: String, subpath: String)

typealias Children = [PathSegment: DependencyNode]

typealias SoftLinkData = String
// Define the DependencyNode enum
enum DependencyNode: Decodable {
    case softLink(data: SoftLinkData)
    case zip(zipInfo: ZipPathInfo, children: Children)
    case dirPortal(target: String, children: Children)
    case nestedDir(children: Children)

    // Implement Decodable protocol
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let linkType = try container.decode(LinkType.self, forKey: .linkType)
        let target = try container.decodeIfPresent(String.self, forKey: .target)

        switch linkType {
        case .SOFT:
            guard let targetPath = target else {
                throw MyError.badManifest("Soft link requires a target")
            }
            self = .softLink(data: targetPath)

        case .HARD:

            let children = try container.decode(
                Children.self, forKey: .children)

            // Validate children paths
            for (key, _) in children {
                // Check that the key (path segment) is a valid file or directory name
                // and doesn't contain nested path components
                if key.contains("/") {
                    throw MyError.badManifest("Invalid path segment: '\(key)'. Path segments should not contain nested paths.")
                }
            }

            if let targetPath = target {
                if let zipRange = targetPath.range(of: ".zip") {
                    let zipPath = String(targetPath[..<zipRange.upperBound])
                    var subpath = String(targetPath[zipRange.upperBound...])
                    if subpath.isEmpty {
                        subpath = "/"
                    }
                    self = .zip(zipInfo: (zipPath: zipPath, subpath: subpath), children: children)
                } else {
                    throw MyError.badManifest("Dir portal is not supported")
                    // self = .dirPortal(target: targetPath, children: children)
                }
            } else {
                self = .nestedDir(children: children)
            }

        // Check if the target has a .zip extension

        }
    }

    // Deserialize from JSON data
    static func fromJSONData(_ data: Data) throws -> DependencyNode {
        let decoder = JSONDecoder()
        return try decoder.decode(DependencyNode.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case children
        case linkType
        case target
    }
}



typealias ZipInfo = (cachedZip: CachedZip, subpath: String)



