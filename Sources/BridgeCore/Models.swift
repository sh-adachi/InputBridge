import Foundation

public struct BridgeError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum JSON {
    public static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    public static func string<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try data(value), as: UTF8.self)
    }
    public static func load<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
    public static func save<T: Encodable>(_ value: T, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data(value).write(to: url, options: .atomic)
    }
}

public struct DDCDevice: Codable, Equatable {
    public var manufacturer: String
    public var name: String
    public var serial: String
    public var numericSerial: Int64
    public var edid: String
    public var location: String
    public var upstream: String
    public var downstream: String
    public var serviceAvailable: Bool

    public init(manufacturer: String, name: String, serial: String, numericSerial: Int64, edid: String, location: String, upstream: String, downstream: String, serviceAvailable: Bool) {
        self.manufacturer = manufacturer; self.name = name; self.serial = serial
        self.numericSerial = numericSerial; self.edid = edid; self.location = location
        self.upstream = upstream; self.downstream = downstream; self.serviceAvailable = serviceAvailable
    }
}

public struct VCPReading: Codable, Equatable {
    public var device: DDCDevice
    public var raw: [UInt8]
    public var valid: Bool
    public var error: String?
    public var current: UInt16?
    public var maximum: UInt16?

    public init(device: DDCDevice, raw: [UInt8], transportOK: Bool) {
        self.device = device
        self.raw = raw
        let reason = Self.validate(raw: raw, transportOK: transportOK)
        valid = reason == nil
        error = reason
        if valid {
            current = UInt16(raw[8]) << 8 | UInt16(raw[9])
            maximum = UInt16(raw[6]) << 8 | UInt16(raw[7])
        }
    }

    public static func validate(raw: [UInt8], transportOK: Bool) -> String? {
        guard transportOK else { return "I2C transport failed" }
        guard raw.count == 11 else { return "Unexpected reply size" }
        guard raw[0] == 0x6e, raw[1] == 0x88 else { return "Invalid DDC reply header/length" }
        guard raw[2] == 0x02, raw[3] == 0x00, raw[4] == 0x60 else {
            return "Unsupported VCP or unexpected opcode/result/feature"
        }
        guard raw[5] == 0 || raw[5] == 1 else { return "Invalid VCP type" }
        guard raw.reduce(UInt8(0x50), ^) == 0 else { return "DDC checksum mismatch" }
        return nil
    }
}
