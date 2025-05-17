import Foundation
import FSKit
// import Compression

func decompressDeflate(compressedData: Data, destinationSize: Int) throws -> Data {
    throw NSError(domain: "CompressionError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Decompression not implemented"])
    // throw "not implemented"
    // var decompressedData = Data(count: destinationSize)

    // let bytesDecompressed = decompressedData.withUnsafeMutableBytes { decompressedBuffer in
    //     return compressedData.withUnsafeBytes { compressedBuffer in
    //         // Use Compression framework to decompress
    //         return compression_decode_buffer(
    //             decompressedBuffer.baseAddress!,
    //             destinationSize,
    //             compressedBuffer.baseAddress!,
    //             compressedData.count,
    //             nil,
    //             COMPRESSION_ZLIB
    //         )
    //     }
    // }

    // if bytesDecompressed != destinationSize {
    //     throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
    // }
    // return decompressedData
}
