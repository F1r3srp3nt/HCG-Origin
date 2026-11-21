import Foundation

/// Builds the gateway's self-signed transport certificate (X.509 v3, ECDSA P-256 / SHA-256).
///
/// The certificate is a container for the TLS key only. Nobody validates it against a
/// certificate authority: Connectors authenticate it by the SHA-256 of its
/// SubjectPublicKeyInfo, pinned from the pairing invitation (same rule as HCG Server).
public enum X509SelfSigned {
    /// - Parameters:
    ///   - spkiDER: the P-256 SubjectPublicKeyInfo of the key that will sign the certificate.
    ///   - sign: produces a DER ECDSA-SHA256 signature over the TBSCertificate bytes with that key.
    public static func make(spkiDER: Data, commonName: String, serial: Data, notBefore: Date, notAfter: Date,
                            sign: (Data) throws -> Data) rethrows -> Data {
        let algorithm = sequence(oid([1, 2, 840, 10045, 4, 3, 2])) // ecdsa-with-SHA256
        let name = sequence(set(sequence(oid([2, 5, 4, 3]) + utf8String(commonName))))
        let validity = sequence(time(notBefore) + time(notAfter))
        var serialBytes = serial.isEmpty ? Data([1]) : serial
        serialBytes[serialBytes.startIndex] &= 0x7f // positive INTEGER
        let extensions = explicit(3, sequence(
            sequence(oid([2, 5, 29, 19]) + boolean(true) + octetString(sequence(Data()))) +   // basicConstraints: CA false (critical)
            sequence(oid([2, 5, 29, 15]) + boolean(true) + octetString(bitString(Data([0x80]), unused: 7))) + // keyUsage: digitalSignature
            sequence(oid([2, 5, 29, 37]) + octetString(sequence(oid([1, 3, 6, 1, 5, 5, 7, 3, 1])))) // extKeyUsage: serverAuth
        ))
        let tbs = sequence(
            explicit(0, integer(Data([2]))) + // v3
            integer(serialBytes) + algorithm + name + validity + name + spkiDER + extensions
        )
        let signature = try sign(tbs)
        return sequence(tbs + algorithm + bitString(signature, unused: 0))
    }

    // MARK: DER

    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let n = content.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var len = n
            var bytes: [UInt8] = []
            while len > 0 { bytes.insert(UInt8(len & 0xff), at: 0); len >>= 8 }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(content)
        return out
    }

    static func sequence(_ c: Data) -> Data { tlv(0x30, c) }
    static func set(_ c: Data) -> Data { tlv(0x31, c) }
    static func explicit(_ n: UInt8, _ c: Data) -> Data { tlv(0xa0 | n, c) }
    static func octetString(_ c: Data) -> Data { tlv(0x04, c) }
    static func utf8String(_ s: String) -> Data { tlv(0x0c, Data(s.utf8)) }
    static func boolean(_ b: Bool) -> Data { tlv(0x01, Data([b ? 0xff : 0x00])) }
    static func bitString(_ c: Data, unused: UInt8) -> Data { tlv(0x03, Data([unused]) + c) }

    static func integer(_ bytes: Data) -> Data {
        var b = bytes
        while b.count > 1 && b.first == 0 && (b[b.startIndex + 1] & 0x80) == 0 { b.removeFirst() }
        if let first = b.first, first & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, b)
    }

    static func oid(_ arcs: [UInt]) -> Data {
        var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var v = arc
            var chunk: [UInt8] = [UInt8(v & 0x7f)]
            v >>= 7
            while v > 0 { chunk.insert(UInt8(v & 0x7f) | 0x80, at: 0); v >>= 7 }
            body.append(contentsOf: chunk)
        }
        return tlv(0x06, body)
    }

    /// UTCTime for years before 2050, GeneralizedTime otherwise (RFC 5280 §4.1.2.5).
    static func time(_ date: Date) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy"
        let year = Int(f.string(from: date)) ?? 2000
        if year < 2050 {
            f.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(0x17, Data(f.string(from: date).utf8))
        }
        f.dateFormat = "yyyyMMddHHmmss'Z'"
        return tlv(0x18, Data(f.string(from: date).utf8))
    }
}
