import Foundation

enum WAVFile {
    /// 16-bit mono PCM WAV.
    static func write(samples: Data, sampleRate: Int, to url: URL) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(36 + samples.count))
        data.append("WAVEfmt ".data(using: .ascii)!)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append("data".data(using: .ascii)!)
        append(UInt32(samples.count))
        data.append(samples)
        try data.write(to: url, options: .atomic)
    }
}
