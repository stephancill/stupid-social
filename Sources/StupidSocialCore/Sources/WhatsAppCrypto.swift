import CommonCrypto
import CryptoKit
import Foundation
import Security

/// A Curve25519 key pair as Signal and WhatsApp use it: X25519 for agreement, XEdDSA for signatures
/// (libsignal-go ecc/, ported from scripts/whatsapp-client.py).
public struct WhatsAppKeyPair: Codable, Equatable, Sendable {
    public let privateKey: Data
    public let publicKey: Data

    public init(privateKey: Data, publicKey: Data) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }

    public init(privateKey: Data) throws {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        self.init(privateKey: privateKey, publicKey: key.publicKey.rawRepresentation)
    }

    /// A new key pair with a clamped private key, like libsignal-go's GenerateKeyPair.
    public static func generate() -> WhatsAppKeyPair {
        generate(random: WhatsAppCipher.randomBytes)
    }

    static func generate(random: (Int) -> Data) -> WhatsAppKeyPair {
        var privateKey = random(32)
        privateKey[privateKey.startIndex] &= 248
        privateKey[privateKey.startIndex + 31] &= 127
        privateKey[privateKey.startIndex + 31] |= 64
        // A 32-byte key is always accepted.
        return try! WhatsAppKeyPair(privateKey: privateKey)
    }

    public func agree(with publicKey: Data) throws -> Data {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey))
        return secret.withUnsafeBytes { Data($0) }
    }

    public func sign(_ message: Data) -> Data {
        WhatsAppXEdDSA.sign(privateKey: privateKey, message: message)
    }

    func sign(_ message: Data, random: (Int) -> Data) -> Data {
        WhatsAppXEdDSA.sign(privateKey: privateKey, message: message, random: random(64))
    }
}

/// XEdDSA as libsignal-go implements it (ecc/SignCurve25519.go): the Edwards public key's sign bit
/// travels in the top bit of the signature instead of negating the private scalar.
public enum WhatsAppXEdDSA {
    public static func sign(privateKey: Data, message: Data, random: Data = WhatsAppCipher.randomBytes(64)) -> Data {
        precondition(privateKey.count == 32 && random.count == 64, "XEdDSA takes a 32-byte key and 64 random bytes")
        var scalar = [UInt8](privateKey)
        scalar[0] &= 248
        scalar[31] &= 127
        scalar[31] |= 64
        let publicKey = Ed25519Point.base.multiplied(by: scalar).encoded()

        var nonceHash = SHA512()
        nonceHash.update(data: [0xFE] + [UInt8](repeating: 0xFF, count: 31))
        nonceHash.update(data: privateKey)
        nonceHash.update(data: message)
        nonceHash.update(data: random)
        let r = Ed25519Scalar.reduce([UInt8](nonceHash.finalize()))
        let encodedR = Ed25519Point.base.multiplied(by: r).encoded()

        var challengeHash = SHA512()
        challengeHash.update(data: encodedR)
        challengeHash.update(data: publicKey)
        challengeHash.update(data: message)
        let h = Ed25519Scalar.reduce([UInt8](challengeHash.finalize()))

        var signature = encodedR + Ed25519Scalar.multiplyAdd(h, scalar, r)
        signature[63] |= publicKey[31] & 0x80
        return Data(signature)
    }

    public static func verify(publicKey: Data, message: Data, signature: Data) -> Bool {
        guard publicKey.count == 32, signature.count == 64 else { return false }
        // Montgomery u to Edwards y = (u - 1) / (u + 1); the field decoding drops u's top bit.
        let u = Ed25519Field(bytes: [UInt8](publicKey))
        let y = (u - .one) * (u + .one).inverted()
        var edwards = y.bytes()
        var signature = [UInt8](signature)
        edwards[31] |= signature[63] & 0x80
        signature[63] &= 0x7F
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: edwards) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}

public enum WhatsAppCipherError: Error, Equatable {
    case badKeyLength
    case badInputLength
    case badPadding
    case authenticationFailed
    case commonCrypto(Int32)
}

/// The symmetric primitives WhatsApp uses, with the probe's conventions (an absent HKDF salt is all zeros;
/// AES-GCM output is ciphertext followed by the 16-byte tag).
public enum WhatsAppCipher {
    public static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return data
    }

    public static func hkdf(_ key: Data, length: Int, salt: Data? = nil, info: Data = Data()) -> Data {
        // An empty HMAC key is zero-padded to the block size, the same as RFC 5869's all-zero default salt.
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: salt ?? Data(), info: info, outputByteCount: length)
        return derived.withUnsafeBytes { Data($0) }
    }

    public static func hmacSHA256(key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    public static func hmacSHA512(key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// AES-256-CBC with PKCS#7 padding.
    public static func aesCBCEncrypt(key: Data, iv: Data, _ plaintext: Data) throws -> Data {
        let pad = 16 - plaintext.count % 16
        return try aes(mode: kCCModeCBC, operation: kCCEncrypt, key: key, iv: iv, plaintext + Data(repeating: UInt8(pad), count: pad))
    }

    public static func aesCBCDecrypt(key: Data, iv: Data, _ ciphertext: Data) throws -> Data {
        guard !ciphertext.isEmpty, ciphertext.count % 16 == 0 else { throw WhatsAppCipherError.badInputLength }
        let padded = try aes(mode: kCCModeCBC, operation: kCCDecrypt, key: key, iv: iv, ciphertext)
        let pad = Int(padded.last!)
        guard (1 ... 16).contains(pad), padded.suffix(pad).allSatisfy({ $0 == UInt8(pad) }) else { throw WhatsAppCipherError.badPadding }
        return padded.dropLast(pad)
    }

    /// AES-CTR with a big-endian 128-bit counter starting at `iv`; encrypting and decrypting are the same.
    public static func aesCTR(key: Data, iv: Data, _ data: Data) throws -> Data {
        try aes(mode: kCCModeCTR, operation: kCCEncrypt, key: key, iv: iv, data)
    }

    public static func aesGCMSeal(key: Data, nonce: Data, _ plaintext: Data, authenticating associatedData: Data = Data()) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: associatedData)
        return box.ciphertext + box.tag
    }

    public static func aesGCMOpen(key: Data, nonce: Data, _ sealed: Data, authenticating associatedData: Data = Data()) throws -> Data {
        guard sealed.count >= 16 else { throw WhatsAppCipherError.badInputLength }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: associatedData)
        } catch CryptoKitError.authenticationFailure {
            throw WhatsAppCipherError.authenticationFailed
        }
    }

    public static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, length: Int) -> Data {
        var derived = Data(count: length)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), length,
                    )
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return derived
    }

    private static func aes(mode: Int, operation: Int, key: Data, iv: Data, _ input: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256 else { throw WhatsAppCipherError.badKeyLength }
        guard iv.count == kCCBlockSizeAES128 else { throw WhatsAppCipherError.badInputLength }
        var cryptor: CCCryptorRef?
        var status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(operation), CCMode(mode), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                    ivBytes.baseAddress, keyBytes.baseAddress, key.count, nil, 0, 0,
                    CCModeOptions(mode == kCCModeCTR ? kCCModeOptionCTR_BE : 0), &cryptor,
                )
            }
        }
        guard status == kCCSuccess, let cryptor else { throw WhatsAppCipherError.commonCrypto(status) }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: input.count)
        var moved = 0
        status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                CCCryptorUpdate(cryptor, inputBytes.baseAddress, input.count, outputBytes.baseAddress, input.count, &moved)
            }
        }
        guard status == kCCSuccess, moved == input.count else { throw WhatsAppCipherError.commonCrypto(status) }
        return output
    }
}

// MARK: - GF(2^255 - 19), radix 2^51

/// A field element in five 51-bit limbs. Every operation leaves limbs below 2^52, which keeps the
/// 128-bit products in `*` from overflowing.
struct Ed25519Field {
    var l0: UInt64, l1: UInt64, l2: UInt64, l3: UInt64, l4: UInt64

    static let mask: UInt64 = (1 << 51) - 1
    static let zero = Ed25519Field(l0: 0, l1: 0, l2: 0, l3: 0, l4: 0)
    static let one = Ed25519Field(l0: 1, l1: 0, l2: 0, l3: 0, l4: 0)

    init(l0: UInt64, l1: UInt64, l2: UInt64, l3: UInt64, l4: UInt64) {
        (self.l0, self.l1, self.l2, self.l3, self.l4) = (l0, l1, l2, l3, l4)
    }

    /// 32 little-endian bytes; the top bit is ignored.
    init(bytes: [UInt8]) {
        func word(_ offset: Int) -> UInt64 {
            (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
        }
        let (w0, w1, w2, w3) = (word(0), word(8), word(16), word(24))
        l0 = w0 & Self.mask
        l1 = (w0 >> 51 | w1 << 13) & Self.mask
        l2 = (w1 >> 38 | w2 << 26) & Self.mask
        l3 = (w2 >> 25 | w3 << 39) & Self.mask
        l4 = (w3 >> 12) & Self.mask
    }

    /// The canonical 32-byte little-endian encoding.
    func bytes() -> [UInt8] {
        var t = carried()
        var q = (t.l0 + 19) >> 51
        q = (t.l1 + q) >> 51
        q = (t.l2 + q) >> 51
        q = (t.l3 + q) >> 51
        q = (t.l4 + q) >> 51
        t.l0 += 19 * q
        t.l1 += t.l0 >> 51
        t.l0 &= Self.mask
        t.l2 += t.l1 >> 51
        t.l1 &= Self.mask
        t.l3 += t.l2 >> 51
        t.l2 &= Self.mask
        t.l4 += t.l3 >> 51
        t.l3 &= Self.mask
        t.l4 &= Self.mask
        let words = [t.l0 | t.l1 << 51, t.l1 >> 13 | t.l2 << 38, t.l2 >> 26 | t.l3 << 25, t.l3 >> 39 | t.l4 << 12]
        return words.flatMap { word in (0 ..< 8).map { UInt8(truncatingIfNeeded: word >> (8 * UInt64($0))) } }
    }

    // Shifts use &>> and &<< and products use multipliedFullWidth: the generic and 128-bit operators
    // are far slower in debug builds.

    private func carried() -> Ed25519Field {
        Ed25519Field(
            l0: (l0 & Self.mask) &+ (l4 &>> 51) &* 19,
            l1: (l1 & Self.mask) &+ (l0 &>> 51),
            l2: (l2 & Self.mask) &+ (l1 &>> 51),
            l3: (l3 & Self.mask) &+ (l2 &>> 51),
            l4: (l4 & Self.mask) &+ (l3 &>> 51),
        )
    }

    static func + (a: Ed25519Field, b: Ed25519Field) -> Ed25519Field {
        Ed25519Field(l0: a.l0 &+ b.l0, l1: a.l1 &+ b.l1, l2: a.l2 &+ b.l2, l3: a.l3 &+ b.l3, l4: a.l4 &+ b.l4).carried()
    }

    /// Adds 2p before subtracting so limbs never go negative.
    static func - (a: Ed25519Field, b: Ed25519Field) -> Ed25519Field {
        Ed25519Field(
            l0: a.l0 &+ 0xF_FFFF_FFFF_FFDA &- b.l0,
            l1: a.l1 &+ 0xF_FFFF_FFFF_FFFE &- b.l1,
            l2: a.l2 &+ 0xF_FFFF_FFFF_FFFE &- b.l2,
            l3: a.l3 &+ 0xF_FFFF_FFFF_FFFE &- b.l3,
            l4: a.l4 &+ 0xF_FFFF_FFFF_FFFE &- b.l4,
        ).carried()
    }

    /// A 128-bit accumulator; sums of five 51-bit-limb products stay below 2^115.
    private struct Wide {
        var high: UInt64 = 0
        var low: UInt64 = 0

        @inline(__always) mutating func add(_ x: UInt64, _ y: UInt64) {
            let product = x.multipliedFullWidth(by: y)
            let (sum, overflow) = low.addingReportingOverflow(product.low)
            low = sum
            high = high &+ product.high &+ (overflow ? 1 : 0)
        }

        @inline(__always) mutating func add(_ x: UInt64) {
            let (sum, overflow) = low.addingReportingOverflow(x)
            low = sum
            high = high &+ (overflow ? 1 : 0)
        }

        @inline(__always) var shifted: UInt64 {
            low &>> 51 | high &<< 13
        }
    }

    private static func reduce(_ r0: Wide, _ r1: Wide, _ r2: Wide, _ r3: Wide, _ r4: Wide) -> Ed25519Field {
        var (r1, r2, r3, r4) = (r1, r2, r3, r4)
        r1.add(r0.shifted)
        r2.add(r1.shifted)
        r3.add(r2.shifted)
        r4.add(r3.shifted)
        var t0 = Wide()
        t0.add(r4.shifted, 19)
        t0.add(r0.low & mask)
        return Ed25519Field(
            l0: t0.low & mask,
            l1: (r1.low & mask) &+ t0.shifted,
            l2: r2.low & mask,
            l3: r3.low & mask,
            l4: r4.low & mask,
        )
    }

    static func * (a: Ed25519Field, b: Ed25519Field) -> Ed25519Field {
        let b1 = b.l1 &* 19, b2 = b.l2 &* 19, b3 = b.l3 &* 19, b4 = b.l4 &* 19
        var r0 = Wide(), r1 = Wide(), r2 = Wide(), r3 = Wide(), r4 = Wide()
        r0.add(a.l0, b.l0); r0.add(a.l1, b4); r0.add(a.l2, b3); r0.add(a.l3, b2); r0.add(a.l4, b1)
        r1.add(a.l0, b.l1); r1.add(a.l1, b.l0); r1.add(a.l2, b4); r1.add(a.l3, b3); r1.add(a.l4, b2)
        r2.add(a.l0, b.l2); r2.add(a.l1, b.l1); r2.add(a.l2, b.l0); r2.add(a.l3, b4); r2.add(a.l4, b3)
        r3.add(a.l0, b.l3); r3.add(a.l1, b.l2); r3.add(a.l2, b.l1); r3.add(a.l3, b.l0); r3.add(a.l4, b4)
        r4.add(a.l0, b.l4); r4.add(a.l1, b.l3); r4.add(a.l2, b.l2); r4.add(a.l3, b.l1); r4.add(a.l4, b.l0)
        return reduce(r0, r1, r2, r3, r4)
    }

    func squared() -> Ed25519Field {
        let d0 = l0 &* 2, d1 = l1 &* 2, d2 = l2 &* 2, d3 = l3 &* 2
        let l3x19 = l3 &* 19, l4x19 = l4 &* 19
        var r0 = Wide(), r1 = Wide(), r2 = Wide(), r3 = Wide(), r4 = Wide()
        r0.add(l0, l0); r0.add(d1, l4x19); r0.add(d2, l3x19)
        r1.add(d0, l1); r1.add(d2, l4x19); r1.add(l3, l3x19)
        r2.add(d0, l2); r2.add(l1, l1); r2.add(d3, l4x19)
        r3.add(d0, l3); r3.add(d1, l2); r3.add(l4, l4x19)
        r4.add(d0, l4); r4.add(d1, l3); r4.add(l2, l2)
        return Self.reduce(r0, r1, r2, r3, r4)
    }

    private func squared(times: Int) -> Ed25519Field {
        var result = self
        for _ in 0 ..< times {
            result = result.squared()
        }
        return result
    }

    /// self^(p - 2), with ref10's addition chain.
    func inverted() -> Ed25519Field {
        let z2 = squared()
        let z9 = self * z2.squared(times: 2)
        let z11 = z2 * z9
        let z2_5_0 = z9 * z11.squared()
        let z2_10_0 = z2_5_0.squared(times: 5) * z2_5_0
        let z2_20_0 = z2_10_0.squared(times: 10) * z2_10_0
        let z2_40_0 = z2_20_0.squared(times: 20) * z2_20_0
        let z2_50_0 = z2_40_0.squared(times: 10) * z2_10_0
        let z2_100_0 = z2_50_0.squared(times: 50) * z2_50_0
        let z2_200_0 = z2_100_0.squared(times: 100) * z2_100_0
        let z2_250_0 = z2_200_0.squared(times: 50) * z2_50_0
        return z2_250_0.squared(times: 5) * z11
    }

    /// `a` when `choice` is all ones, `b` when it is zero, without branching.
    static func select(_ a: Ed25519Field, _ b: Ed25519Field, _ choice: UInt64) -> Ed25519Field {
        Ed25519Field(
            l0: b.l0 ^ (choice & (a.l0 ^ b.l0)),
            l1: b.l1 ^ (choice & (a.l1 ^ b.l1)),
            l2: b.l2 ^ (choice & (a.l2 ^ b.l2)),
            l3: b.l3 ^ (choice & (a.l3 ^ b.l3)),
            l4: b.l4 ^ (choice & (a.l4 ^ b.l4)),
        )
    }
}

// MARK: - Edwards25519

/// A point in extended coordinates (X:Y:Z:T), x = X/Z, y = Y/Z, xy = T/Z.
struct Ed25519Point {
    var x: Ed25519Field, y: Ed25519Field, z: Ed25519Field, t: Ed25519Field

    static let identity = Ed25519Point(x: .zero, y: .one, z: .one, t: .zero)
    static let d2 = Ed25519Field(bytes: [UInt8](Data(hex: "59f1b226949bd6eb56b183829a14e00030d1f3eef2808e19e7fcdf56dcd90624")))
    static let base: Ed25519Point = {
        let x = Ed25519Field(bytes: [UInt8](Data(hex: "1ad5258f602d56c9b2a7259560c72c695cdcd6fd31e2a4c0fe536ecdd3366921")))
        let y = Ed25519Field(bytes: [UInt8](Data(hex: "5866666666666666666666666666666666666666666666666666666666666666")))
        return Ed25519Point(x: x, y: y, z: .one, t: x * y)
    }()

    /// add-2008-hwcd-3, complete for a = -1, so it also doubles.
    static func + (p: Ed25519Point, q: Ed25519Point) -> Ed25519Point {
        let a = (p.y - p.x) * (q.y - q.x)
        let b = (p.y + p.x) * (q.y + q.x)
        let c = p.t * d2 * q.t
        let zz = p.z * q.z
        let d = zz + zz
        let e = b - a, f = d - c, g = d + c, h = b + a
        return Ed25519Point(x: e * f, y: g * h, z: f * g, t: e * h)
    }

    /// Double-and-always-add over 256 bits of a little-endian scalar.
    func multiplied(by scalar: [UInt8]) -> Ed25519Point {
        var result = Ed25519Point.identity
        for bit in stride(from: 255, through: 0, by: -1) {
            result = result + result
            let sum = result + self
            let choice = 0 &- UInt64((scalar[bit >> 3] >> (bit & 7)) & 1)
            result = Ed25519Point(
                x: .select(sum.x, result.x, choice),
                y: .select(sum.y, result.y, choice),
                z: .select(sum.z, result.z, choice),
                t: .select(sum.t, result.t, choice),
            )
        }
        return result
    }

    func encoded() -> [UInt8] {
        let inverse = z.inverted()
        var encoded = (y * inverse).bytes()
        encoded[31] |= ((x * inverse).bytes()[0] & 1) << 7
        return encoded
    }
}

// MARK: - Scalars mod L = 2^252 + 27742317777372353535851937790883648493

enum Ed25519Scalar {
    private static let order: (UInt64, UInt64, UInt64, UInt64) = (0x5812_631A_5CF5_D3ED, 0x14DE_F9DE_A2F7_9CD6, 0, 0x1000_0000_0000_0000)

    /// A little-endian number of any length reduced mod L, as 32 little-endian bytes.
    static func reduce(_ bytes: [UInt8]) -> [UInt8] {
        // Shift in one bit at a time from the top, subtracting L whenever the remainder reaches it.
        var (r0, r1, r2, r3): (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        for bit in stride(from: bytes.count * 8 - 1, through: 0, by: -1) {
            let incoming = UInt64(bytes[bit &>> 3] &>> UInt8(bit & 7) & 1)
            (r0, r1, r2, r3) = (r0 &<< 1 | incoming, r1 &<< 1 | r0 &>> 63, r2 &<< 1 | r1 &>> 63, r3 &<< 1 | r2 &>> 63)
            let (d0, b0) = subtract(r0, order.0, 0)
            let (d1, b1) = subtract(r1, order.1, b0)
            let (d2, b2) = subtract(r2, order.2, b1)
            let (d3, b3) = subtract(r3, order.3, b2)
            let keep = 0 &- b3
            (r0, r1, r2, r3) = (r0 & keep | d0 & ~keep, r1 & keep | d1 & ~keep, r2 & keep | d2 & ~keep, r3 & keep | d3 & ~keep)
        }
        return [r0, r1, r2, r3].flatMap { word in (0 ..< 8).map { UInt8(truncatingIfNeeded: word &>> UInt64(8 * $0)) } }
    }

    @inline(__always) private static func subtract(_ x: UInt64, _ y: UInt64, _ borrow: UInt64) -> (UInt64, UInt64) {
        let (step, overflow1) = x.subtractingReportingOverflow(y)
        let (value, overflow2) = step.subtractingReportingOverflow(borrow)
        return (value, overflow1 || overflow2 ? 1 : 0)
    }

    /// (a * b + c) mod L for 32-byte little-endian a, b and c.
    static func multiplyAdd(_ a: [UInt8], _ b: [UInt8], _ c: [UInt8]) -> [UInt8] {
        func words(_ bytes: [UInt8]) -> [UInt64] {
            (0 ..< 4).map { word in (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(bytes[word * 8 + $1]) << (8 * UInt64($1)) } }
        }
        let (x, y) = (words(a), words(b))
        var product = [UInt64](repeating: 0, count: 8)
        for i in 0 ..< 4 {
            var carry: UInt64 = 0
            for j in 0 ..< 4 {
                let (high, low) = x[i].multipliedFullWidth(by: y[j])
                let (sum1, overflow1) = low.addingReportingOverflow(product[i + j])
                let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
                product[i + j] = sum2
                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
            }
            product[i + 4] = carry
        }
        let addend = words(c) + [0, 0, 0, 0]
        var carry: UInt64 = 0
        for index in 0 ..< 8 {
            let (sum1, overflow1) = product[index].addingReportingOverflow(addend[index])
            let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
            product[index] = sum2
            carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        return reduce(product.flatMap { word in (0 ..< 8).map { UInt8(truncatingIfNeeded: word >> (8 * UInt64($0))) } })
    }
}
