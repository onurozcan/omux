import Foundation

/// Messages on the wire: each is JSON behind a four-byte length, most significant byte first.
/// The same framing over a local socket or the standard streams of an SSH connection.
public enum Wire {
    /// Larger than any message the protocol sends; a length beyond it means the stream is not ours.
    public static let maxFrame = 16 << 20

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder().encode(value)
        var frame = Data(capacity: body.count + 4)
        let length = UInt32(body.count)
        frame.append(contentsOf: [UInt8(length >> 24), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
        frame.append(body)
        return frame
    }

    public static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }

    public enum Failure: Error { case tooLarge(Int) }

    /// Cuts a byte stream back into messages, however the bytes were split on the way.
    public struct Splitter {
        private var buffer = Data()
        public init() {}

        public mutating func feed(_ data: Data) throws -> [Data] {
            buffer.append(data)
            var frames: [Data] = []
            while buffer.count >= 4 {
                let start = buffer.startIndex
                let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
                guard length <= Wire.maxFrame else { throw Failure.tooLarge(length) }
                guard buffer.count >= 4 + length else { break }
                frames.append(Data(buffer[(start + 4)..<(start + 4 + length)]))
                buffer = Data(buffer[(start + 4 + length)...])
            }
            return frames
        }
    }
}
