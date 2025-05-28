import FSKit


let STATIC_BITS_OFFSET = 40
let PARENT_BITS_OFFSET = 20


func offsetNum(_ num: UInt64, offset: Int) -> UInt64 {
    let maxNum = UInt64.max >> offset
    guard num <= maxNum else {
        fatalError("Number \(num) exceeds maximum size for offset \(offset)")
    }
    return num << offset
}

public class Inodes {
    var staticNodes: Array<FSItemProtocol> = []


    func addStatic(node: FSItemProtocol) -> UInt64 {
        let nextInd = staticNodes.count
        staticNodes.append(node)

        let offsettedInd = offsetNum(UInt64(nextInd), offset: STATIC_BITS_OFFSET)

    }
    func getInode(static: FSItemProtocol, zip: ZipID) -> UInt64 {
        
    }


    func getNodeFromId(id: UInt64) -> FSItemProtocol? {
        let staticInd = id >> STATIC_BITS_OFFSET
        
    }
        
}