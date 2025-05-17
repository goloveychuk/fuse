import Foundation

public class FSFileName {
    public let data : Data
    public init(data: Data) {
        self.data = data
    }
}


open class FSItem : NSObject {
    
}

extension FSItem {

    /// Attributes of an item, such as size, creation and modification times, and user and group identifiers.
    // open class Attributes : NSObject, NSSecureCoding {

    //     /// Marks all attributes inactive.
    //     open func invalidateAllProperties()

    //     /// The user identifier.
    //     open var uid: UInt32

    //     /// The group identifier.
    //     open var gid: UInt32

    //     /// The mode of the item.
    //     ///
    //     /// The mode is often used for `setuid`, `setgid`, and `sticky` bits.
    //     open var mode: UInt32

    //     /// The item type, such as a regular file, directory, or symbolic link.
    //     open var type: FSItem.ItemType

    //     /// The number of hard links to the item.
    //     open var linkCount: UInt32

    //     /// The item's behavior flags.
    //     ///
    //     /// See `st_flags` in `stat.h` for flag definitions.
    //     open var flags: UInt32

    //     /// The item's size.
    //     open var size: UInt64

    //     /// The item's allocated size.
    //     open var allocSize: UInt64

    //     /// The item's file identifier.
    //     open var fileID: FSItem.Identifier

    //     /// The identifier of the item's parent.
    //     open var parentID: FSItem.Identifier

    //     /// A Boolean value that indicates whether the item supports a limited set of extended attributes.
    //     open var supportsLimitedXAttrs: Bool

    //     /// A Boolean value that indicates whether the file system overrides the per-volume settings for kernel offloaded I/O for a specific file.
    //     ///
    //     /// This property has no meaning if the volume doesn't conform to ``FSVolumeKernelOffloadedIOOperations``.
    //     open var inhibitKernelOffloadedIO: Bool

    //     /// The item's last-modified time.
    //     ///
    //     /// This property represents `mtime`, the last time the item's contents changed.
    //     open var modifyTime: timespec

    //     /// The item's added time.
    //     ///
    //     /// This property represents the time the file system added the item to its parent directory.
    //     open var addedTime: timespec

    //     /// The item's last-changed time.
    //     ///
    //     /// This property represents `ctime`, the last time the item's metadata changed.
    //     open var changeTime: timespec

    //     /// The item's last-accessed time.
    //     open var accessTime: timespec

    //     /// The item's creation time.
    //     open var birthTime: timespec

    //     /// The item's last-backup time.
    //     open var backupTime: timespec

    //     /// Returns a Boolean value that indicates whether the attribute is valid.
    //     ///
    //     /// If the value returned by this method is `YES` (Objective-C) or `true` (Swift), a caller can safely use the given attribute.
    //     open func isValid(_ attribute: FSItem.Attribute) -> Bool
    // }

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
    // open class GetAttributesRequest : NSObject, NSSecureCoding {

    //     /// The attributes requested by the request.
    //     ///
    //     /// This property is a bit field in Objective-C and an <doc://com.apple.documentation/documentation/Swift/OptionSet> in Swift.
    //     open var wantedAttributes: FSItem.Attribute

    //     /// A method that indicates whether the request wants given attribute.
    //     ///
    //     /// - Parameter attribute: The ``FSItemAttribute`` to check.
    //     open func isAttributeWanted(_ attribute: FSItem.Attribute) -> Bool
    // }

    /// A value that indicates a set of item attributes to get or set.
    ///
    /// This type is an option set in Swift.
    /// In Objective-C, you use the cases of this enumeration to create a bit field.
    // public struct Attribute : OptionSet, @unchecked Sendable {

    //     public init(rawValue: Int)

    //     /// The type attribute.
    //     public static var type: FSItem.Attribute { get }

    //     /// The mode attribute.
    //     public static var mode: FSItem.Attribute { get }

    //     /// The link count attribute.
    //     public static var linkCount: FSItem.Attribute { get }

    //     /// The user ID (uid) attribute.
    //     public static var uid: FSItem.Attribute { get }

    //     /// The group ID (gid) attribute.
    //     public static var gid: FSItem.Attribute { get }

    //     /// The flags attribute.
    //     public static var flags: FSItem.Attribute { get }

    //     /// The size attribute.
    //     public static var size: FSItem.Attribute { get }

    //     /// The allocated size attribute.
    //     public static var allocSize: FSItem.Attribute { get }

    //     /// The file ID attribute.
    //     public static var fileID: FSItem.Attribute { get }

    //     /// The parent ID attribute.
    //     public static var parentID: FSItem.Attribute { get }

    //     /// The last-accessed time attribute.
    //     public static var accessTime: FSItem.Attribute { get }

    //     /// The last-modified time attribute.
    //     public static var modifyTime: FSItem.Attribute { get }

    //     /// The last-changed time attribute.
    //     public static var changeTime: FSItem.Attribute { get }

    //     /// The creation time attribute.
    //     public static var birthTime: FSItem.Attribute { get }

    //     /// The backup time attribute.
    //     public static var backupTime: FSItem.Attribute { get }

    //     /// The time added attribute.
    //     public static var addedTime: FSItem.Attribute { get }

    //     /// The supports limited extended attributes attribute.
    //     public static var supportsLimitedXAttrs: FSItem.Attribute { get }

    //     /// The inhibit kernel offloaded I/O attribute.
    //     public static var inhibitKernelOffloadedIO: FSItem.Attribute { get }
    // }

    /// An enumeration of item types, such as file, directory, or symbolic link.
    public enum ItemType : Int, @unchecked Sendable {

        case unknown = 0

        case file = 1

        case directory = 2

        case symlink = 3

        case fifo = 4

        case charDevice = 5

        case blockDevice = 6

        case socket = 7
    }

    public enum Identifier : UInt64, @unchecked Sendable {

        case invalid = 0

        case parentOfRoot = 1

        case rootDirectory = 2
    }
}




  