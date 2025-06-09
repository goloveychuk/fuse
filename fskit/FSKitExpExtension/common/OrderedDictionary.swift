



struct OrderedDictionary<Key: StringProtocol & Sendable, Value: Sendable> {
    private let dict: [Key: Value]
    private let sortedEntries: [(Key, Value)]
    init(_ dict: [Key: Value]) {
        self.dict = dict
        self.sortedEntries = dict.sorted(by: { $0.key < $1.key })
    }

    func entries() -> [(Key, Value)] {
        return sortedEntries
    }

    subscript(key: Key) -> Value? {
        get {
            return dict[key]
        }
    }
    
}
