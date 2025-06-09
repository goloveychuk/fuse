import Foundation

public class FSFileName {
    public let data : Data
    public init(data: Data) {
        self.data = data
    }
    public var string: String? {
        return String(data: data, encoding: .utf8)
    }
    public convenience init(string name: String) {
        self.init(data: name.data(using: .utf8)!)
    }

}

open class FSVolume {
    public init() {

    }
}

public typealias FSItem = NSObject

// open class FSItem : NSObject {

// }

public func fs_errorForPOSIXError(_: Int32) -> any Error {

    return NSError(domain: "domain", code: 0, userInfo: nil)
}

public struct FSDirectoryVerifier: Sendable {  //not used
    public init(_ rawValue: UInt64) {

    }
}


// open class FSMutableFileDataBuffer {
//     // open var length: Int { get }


//     public func withUnsafeMutableBytes<R, E>(_ body: (UnsafeMutableRawBufferPointer)  throws(E) -> R) throws(E) -> R where E : Error {
//         //todo
//         return try body(UnsafeMutableRawBufferPointer.allocate(byteCount: 0, alignment: 0))
//     }

// }


extension FSItem {

    /// Attributes of an item, such as size, creation and modification times, and user and group identifiers.
    open class Attributes : NSObject {

        /// Marks all attributes inactive.
        // open func invalidateAllProperties()

        /// The user identifier.
        open var uid: UInt32 = 0

        /// The group identifier.
        open var gid: UInt32 = 0

        /// The mode of the item.
        ///
        /// The mode is often used for `setuid`, `setgid`, and `sticky` bits.
        open var mode: UInt32 = 0

        /// The item type, such as a regular file, directory, or symbolic link.
        open var type: FSItem.ItemType = .unknown

        /// The number of hard links to the item.
        open var linkCount: UInt32 = 0

        /// The item's behavior flags.
        ///
        /// See `st_flags` in `stat.h` for flag definitions.
        open var flags: UInt32 = 0

        /// The item's size.
        open var size: UInt64 = 0

        /// The item's allocated size.
        open var allocSize: UInt64 = 0

        /// The item's file identifier.
        open var fileID: FSItem.Identifier = .invalid

        /// The identifier of the item's parent.
        open var parentID: FSItem.Identifier = .invalid

        /// A Boolean value that indicates whether the item supports a limited set of extended attributes.
        open var supportsLimitedXAttrs: Bool = false

        /// A Boolean value that indicates whether the file system overrides the per-volume settings for kernel offloaded I/O for a specific file.
        ///
        /// This property has no meaning if the volume doesn't conform to ``FSVolumeKernelOffloadedIOOperations``.
        open var inhibitKernelOffloadedIO: Bool = false

        /// The item's last-modified time.
        ///
        /// This property represents `mtime`, the last time the item's contents changed.
        open var modifyTime: timespec = timespec()

        /// The item's added time.
        ///
        /// This property represents the time the file system added the item to its parent directory.
        open var addedTime: timespec = timespec()

        /// The item's last-changed time.
        ///
        /// This property represents `ctime`, the last time the item's metadata changed.
        open var changeTime: timespec = timespec()

        /// The item's last-accessed time.
        open var accessTime: timespec = timespec()

        /// The item's creation time.
        open var birthTime: timespec = timespec()

        /// The item's last-backup time.
        open var backupTime: timespec = timespec()

        /// Returns a Boolean value that indicates whether the attribute is valid.
        ///
        /// If the value returned by this method is `YES` (Objective-C) or `true` (Swift), a caller can safely use the given attribute.
        // open func isValid(_ attribute: FSItem.Attribute) -> Bool
    }

    /// A request to set attributes on an item.
    ///
    /// Methods that take attributes use this type to receive attribute values and to indicate which attributes they support.
    /// The various members of the parent type, ``FSItemAttributes``, contain the values of the attributes to set.
    ///
    /// Modify the ``consumedAttributes`` property to indicate which attributes your file system successfully used.
    /// FSKit calls the ``wasAttributeConsumed(_:)`` method to determine whether the file system successfully used a given attribute.
    /// Only set the attributes that your file system supports.
    // open class SetAttributesRequest : FSItem.Attributes {

    //     /// The attributes successfully used by the file system.
    //     ///
    //     /// This property is a bit field in Objective-C and an <doc://com.apple.documentation/documentation/Swift/OptionSet> in Swift.
    //     open var consumedAttributes: FSItem.Attribute

    //     /// A method that indicates whether the file system used the given attribute.
    //     ///
    //     /// - Parameter attribute: The ``FSItemAttribute`` to check.
    //     open func wasAttributeConsumed(_ attribute: FSItem.Attribute) -> Bool
    // }

    // /// A request to get attributes from an item.
    // ///
    // /// Methods that retrieve attributes use this type and inspect the ``wantedAttributes`` property to determine which attributes to provide. FSKit calls the ``isAttributeWanted(_:)`` method to determine whether the request requires a given attribute.
    public final class GetAttributesRequest : NSObject, Sendable {
        
        /// The attributes requested by the request.
        ///
        /// This property is a bit field in Objective-C and an <doc://com.apple.documentation/documentation/Swift/OptionSet> in Swift.
        public let wantedAttributes: FSItem.Attribute

        public init(_ wantedAttributes: FSItem.Attribute) {
            self.wantedAttributes = wantedAttributes
        }

        /// A method that indicates whether the request wants given attribute.
        ///
        /// - Parameter attribute: The ``FSItemAttribute`` to check.
        public func isAttributeWanted(_ attribute: FSItem.Attribute) -> Bool {
            return wantedAttributes.contains(attribute)
        }
    }


    public struct Attribute : OptionSet, Sendable  {
        public let rawValue: Int
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }
        /// The type attribute.
        public static let type = Attribute(rawValue: 1 << 0)

        /// The mode attribute.
        public static let mode = Attribute(rawValue: 1 << 1)

        /// The link count attribute.
        public static let linkCount = Attribute(rawValue: 1 << 2)

        /// The user ID (uid) attribute.
        public static let uid = Attribute(rawValue: 1 << 3)

        /// The group ID (gid) attribute.
        public static let gid = Attribute(rawValue: 1 << 4)

        /// The flags attribute.
        public static let flags = Attribute(rawValue: 1 << 5)

        /// The size attribute.
        public static let size = Attribute(rawValue: 1 << 6)

        /// The allocated size attribute.
        public static let allocSize = Attribute(rawValue: 1 << 7)

        /// The file ID attribute.
        public static let fileID = Attribute(rawValue: 1 << 8)

        /// The parent ID attribute.
        public static let parentID = Attribute(rawValue: 1 << 9)

        /// The last-accessed time attribute.
        public static let accessTime = Attribute(rawValue: 1 << 10)

        /// The last-modified time attribute.
        public static let modifyTime = Attribute(rawValue: 1 << 11)

        /// The last-changed time attribute.
        public static let changeTime = Attribute(rawValue: 1 << 12)

        /// The creation time attribute.
        public static let birthTime = Attribute(rawValue: 1 << 13)

        /// The backup time attribute.
        public static let backupTime = Attribute(rawValue: 1 << 14)

        /// The time added attribute.
        public static let addedTime = Attribute(rawValue: 1 << 15)

        /// The supports limited extended attributes attribute.
        public static let supportsLimitedXAttrs = Attribute(rawValue: 1 << 16)

        /// The inhibit kernel offloaded I/O attribute.
        public static let inhibitKernelOffloadedIO = Attribute(rawValue: 1 << 17)
    }

    /// An enumeration of item types, such as file, directory, or symbolic link.
    public enum ItemType : Int, Sendable {

        case unknown = 0

        case file = 1

        case directory = 2

        case symlink = 3

        case fifo = 4

        case charDevice = 5

        case blockDevice = 6

        case socket = 7
    }

    public struct Identifier: RawRepresentable, Equatable, Sendable {
        public var rawValue: UInt64
        
        public init?(rawValue: UInt64) {
            self.rawValue = rawValue
        }
        
        // Define the same constants that were previously enum cases
        public static let invalid = Identifier(rawValue: 0)!
        public static let parentOfRoot = Identifier(rawValue: 1)!
        public static let rootDirectory = Identifier(rawValue: 1)! //todo not sure
    }
}

// public typealias FSDirectoryCookie = Int

public struct FSDirectoryCookie : RawRepresentable, Sendable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

extension FSDirectoryCookie {

//     /// The constant initial value for the directory-enumeration cookie.
//     @available(macOS 15.4, *)
    public static let initial: FSDirectoryCookie = FSDirectoryCookie(0)
}

public protocol FSDirectoryEntryPacker  {

    /// Provides a directory entry during enumeration.
    ///
    /// You call this method in your implementation of ``FSVolume/Operations/enumerateDirectory(_:startingAt:verifier:attributes:packer:replyHandler:)``, for each directory entry you want to provide to the enumeration.
    ///
    /// - Parameters:
    ///   - name: The item's name.
    ///   - itemType: The type of the item.
    ///   - itemID: The item's identifier.
    ///   - nextCookie: A value to indicate the next entry in the directory to enumerate. FSKit passes this value as the `cookie` parameter on the next call to ``FSVolume/Operations/enumerateDirectory(_:startingAt:verifier:attributes:packer:replyHandler:)``. Use whatever value is appropriate for your implementation; the value is opaque to FSKit.
    ///   - attributes: The item's attributes. Pass `nil` if the enumeration call didn't request attributes.
    /// - Returns: `true` (Swift) or `YES` (Objective-C) if packing was successful and enumeration can continue with the next directory entry. If the value is `false` (Swift) or `NO` (Objective-C), stop enumerating. This result can happen when the entry is too big for the remaining space in the buffer.

    func packEntry(name: FSFileName, itemType: FSItem.ItemType, itemID: FSItem.Identifier, nextCookie: FSDirectoryCookie, attributes: FSItem.Attributes?) -> Bool
}
