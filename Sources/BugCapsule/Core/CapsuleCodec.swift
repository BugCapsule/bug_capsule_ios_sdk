import Foundation

public struct CapsuleFormatError: Error, CustomStringConvertible, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "CapsuleFormatError: \(message)" }
}

/// Reads and writes `.bugcapsule` files (gzip-compressed UTF-8 JSON). Reads
/// spec v1 and v2; writes v2 when the capsule has interaction dependencies
/// (capsule-v2 §1) or is a crash capsule (crash-capsules §2), v1 otherwise.
///
/// Decoding is bounded at every step: gzip output is capped while it is
/// inflated, JSON values are counted before parsing (4,000,000), parsing
/// is depth-limited and the document is validated structurally before any
/// model is built.
public enum CapsuleCodec {
    public static let format = "bugcapsule.capsule"
    /// The newest spec version this reader implements.
    public static let specVersion = 2
    /// Same ceiling as the Dart reader (above the backend's 64 MB upload limit).
    public static let maxDecompressedBytes = 200 * 1024 * 1024

    /// The version a capsule is written as: 2 with dependencies or a crash, else 1.
    public static func writeVersion(_ capsule: Capsule) -> Int { capsule.manifest.isV2 ? 2 : 1 }

    public static func toJSON(_ capsule: Capsule) -> JSONValue {
        [
            "format": .string(format),
            "specVersion": .int(writeVersion(capsule)),
            "manifest": capsule.manifest.json,
            "checkpoint": capsule.checkpoint.json,
            "events": .array(capsule.events.map(\.json)),
        ]
    }

    public static func encode(_ capsule: Capsule) throws -> Data {
        try Gzip.compress(JSON.encodeData(toJSON(capsule)))
    }

    public static func decode(_ data: Data, maxDecompressedBytes: Int = maxDecompressedBytes) throws -> Capsule {
        guard Gzip.isGzip(data) else { throw CapsuleFormatError("not a gzip file") }
        let raw: Data
        do {
            raw = try Gzip.decompress(data, maxBytes: maxDecompressedBytes)
        } catch GzipError.tooLarge {
            throw CapsuleFormatError("decompressed capsule exceeds \(maxDecompressedBytes) bytes")
        } catch {
            throw CapsuleFormatError("not a valid gzip file")
        }
        let bytes = [UInt8](raw)
        if countJSONValues(bytes, limit: CapsuleLimits.maxJSONValues) > CapsuleLimits.maxJSONValues {
            throw CapsuleFormatError("$ has more than \(CapsuleLimits.maxJSONValues) JSON values")
        }
        let json: JSONValue
        do {
            json = try JSON.parse(bytes)
        } catch let e as JSONParseError {
            if e.message == "nesting too deep" {
                throw CapsuleFormatError("malformed capsule: $ nests deeper than \(CapsuleLimits.maxDepth) levels")
            }
            throw CapsuleFormatError("invalid JSON: \(e.description)")
        }
        guard case .object(let o) = json else { throw CapsuleFormatError("top level is not an object") }
        return try fromJSON(o)
    }

    /// Validates the whole document before building the model, so malformed
    /// input fails with an error naming the JSON path.
    public static func fromJSON(_ json: JSONObject) throws -> Capsule {
        guard json["format"] == .string(format) else {
            let got: String
            switch json["format"] {
            case .string(let s)?: got = s
            case nil, .null?: got = "null"
            case let v?: got = JSON.encode(v)
            }
            throw CapsuleFormatError("$.format must be \"\(format)\" (got \"\(got)\")")
        }
        guard case .int(let version)? = json["specVersion"] else {
            throw CapsuleFormatError("$.specVersion must be an integer")
        }
        if version > specVersion {
            throw CapsuleFormatError(
                "$.specVersion \(version) is newer than this reader (v\(specVersion)); update BugCapsule")
        }
        if let problem = validateCapsuleDocument(.object(json)) {
            throw CapsuleFormatError("malformed capsule: \(problem)")
        }
        return Capsule(
            manifest: CapsuleManifest(json: json["manifest"]!.objectValue!, specVersion: version),
            checkpoint: Checkpoint(json: json["checkpoint"]!.objectValue!),
            events: (json["events"]!.arrayValue!).map { BugCapsuleEvent(json: $0.objectValue!) })
    }

    /// Values in UTF-8 JSON without parsing (`{`, `[` and `,` outside strings,
    /// plus one); stops past [limit]. Same rule as the Dart reader and backend.
    public static func countJSONValues(_ buf: [UInt8], limit: Int) -> Int {
        var n = 1
        var inString = false
        var i = 0
        let count = buf.count
        while i < count {
            let c = buf[i]
            if inString {
                if c == 0x5C {
                    i += 1
                } else if c == 0x22 {
                    inString = false
                }
            } else if c == 0x22 {
                inString = true
            } else if c == 0x7B || c == 0x5B || c == 0x2C {
                n += 1
                if n > limit { return n }
            }
            i += 1
        }
        return n
    }
}
