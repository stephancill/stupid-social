import CommonCrypto
import CryptoKit
import Foundation
import Security

/// An unsigned big integer, just enough for MTProto: 2048-bit DH and RSA, and SRP for 2FA passwords.
/// Limbs are little-endian `UInt64`s with no trailing zero limbs.
struct BigUInt: Comparable {
    private(set) var limbs: [UInt64]

    init(_ value: UInt64 = 0) {
        limbs = value == 0 ? [] : [value]
    }

    init(limbs: [UInt64]) {
        self.limbs = limbs
        normalize()
    }

    /// From big-endian bytes, as TL `bytes` carry numbers.
    init(bytes: Data) {
        var limbs = [UInt64](repeating: 0, count: (bytes.count + 7) / 8)
        for (index, byte) in bytes.reversed().enumerated() {
            limbs[index / 8] |= UInt64(byte) << (8 * UInt64(index % 8))
        }
        self.init(limbs: limbs)
    }

    /// Big-endian bytes, left-padded to `length`, or minimal when `length` is nil.
    func bytes(length: Int? = nil) -> Data {
        var out = [UInt8]()
        for limb in limbs.reversed() {
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift)))
            }
        }
        while let first = out.first, first == 0 {
            out.removeFirst()
        }
        if let length {
            precondition(out.count <= length, "BigUInt doesn't fit in \(length) bytes")
            out.insert(contentsOf: [UInt8](repeating: 0, count: length - out.count), at: 0)
        }
        return Data(out)
    }

    var isZero: Bool {
        limbs.isEmpty
    }

    var bitWidth: Int {
        guard let last = limbs.last else { return 0 }
        return (limbs.count - 1) * 64 + (64 - last.leadingZeroBitCount)
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 64
        return limb < limbs.count && (limbs[limb] >> UInt64(index % 64)) & 1 == 1
    }

    private mutating func normalize() {
        while limbs.last == 0 {
            limbs.removeLast()
        }
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result = [UInt64](repeating: 0, count: max(lhs.limbs.count, rhs.limbs.count) + 1)
        var carry: UInt64 = 0
        for index in 0 ..< result.count - 1 {
            let a = index < lhs.limbs.count ? lhs.limbs[index] : 0
            let b = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (sum1, overflow1) = a.addingReportingOverflow(b)
            let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
            result[index] = sum2
            carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        result[result.count - 1] = carry
        return BigUInt(limbs: result)
    }

    /// `lhs - rhs`, which must not be negative.
    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(lhs >= rhs, "BigUInt subtraction underflow")
        var result = lhs.limbs
        var borrow: UInt64 = 0
        for index in 0 ..< result.count {
            let b = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (diff1, overflow1) = result[index].subtractingReportingOverflow(b)
            let (diff2, overflow2) = diff1.subtractingReportingOverflow(borrow)
            result[index] = diff2
            borrow = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        return BigUInt(limbs: result)
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        guard !lhs.isZero, !rhs.isZero else { return BigUInt() }
        var result = [UInt64](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0 ..< lhs.limbs.count {
            var carry: UInt64 = 0
            for j in 0 ..< rhs.limbs.count {
                let (high, low) = lhs.limbs[i].multipliedFullWidth(by: rhs.limbs[j])
                let (sum1, overflow1) = low.addingReportingOverflow(result[i + j])
                let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
                result[i + j] = sum2
                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
            }
            result[i + rhs.limbs.count] = carry
        }
        return BigUInt(limbs: result)
    }

    static func ^ (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result = [UInt64](repeating: 0, count: max(lhs.limbs.count, rhs.limbs.count))
        for index in 0 ..< result.count {
            result[index] = (index < lhs.limbs.count ? lhs.limbs[index] : 0) ^ (index < rhs.limbs.count ? rhs.limbs[index] : 0)
        }
        return BigUInt(limbs: result)
    }
}

/// Arithmetic modulo an odd number in Montgomery form, for fast modular exponentiation.
struct Montgomery {
    let modulus: BigUInt
    private let m: [UInt64]
    private let n: Int
    private let inverse: UInt64
    /// R² mod m, with R = 2^(64n).
    private let rSquared: [UInt64]

    init(modulus: BigUInt) {
        precondition(modulus.bit(0), "Montgomery needs an odd modulus")
        self.modulus = modulus
        m = modulus.limbs
        n = m.count
        // -m⁻¹ mod 2^64 by Newton's iteration.
        var x: UInt64 = 1
        for _ in 0 ..< 6 {
            x = x &* (2 &- m[0] &* x)
        }
        inverse = 0 &- x
        var r = BigUInt(1)
        for _ in 0 ..< 128 * m.count {
            r = r + r
            if r >= modulus {
                r = r - modulus
            }
        }
        rSquared = r.limbs + [UInt64](repeating: 0, count: m.count - r.limbs.count)
    }

    private func padded(_ value: BigUInt) -> [UInt64] {
        value.limbs + [UInt64](repeating: 0, count: n - value.limbs.count)
    }

    /// a·b·R⁻¹ mod m (CIOS), on raw buffers: it runs thousands of times per exponentiation.
    private func multiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let n = n
        let inverse = inverse
        var t = [UInt64](repeating: 0, count: n + 2)
        t.withUnsafeMutableBufferPointer { t in
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    m.withUnsafeBufferPointer { m in
                        for i in 0 ..< n {
                            var carry: UInt64 = 0
                            let bi = b[i]
                            for j in 0 ..< n {
                                let (high, low) = a[j].multipliedFullWidth(by: bi)
                                let (sum1, overflow1) = low.addingReportingOverflow(t[j])
                                let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
                                t[j] = sum2
                                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
                            }
                            let (sum, overflow) = t[n].addingReportingOverflow(carry)
                            t[n] = sum
                            t[n + 1] = overflow ? 1 : 0

                            let factor = t[0] &* inverse
                            let (high0, low0) = factor.multipliedFullWidth(by: m[0])
                            let (_, overflow0) = low0.addingReportingOverflow(t[0])
                            carry = high0 &+ (overflow0 ? 1 : 0)
                            for j in 1 ..< n {
                                let (high, low) = factor.multipliedFullWidth(by: m[j])
                                let (sum1, overflow1) = low.addingReportingOverflow(t[j])
                                let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
                                t[j - 1] = sum2
                                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
                            }
                            let (sumN, overflowN) = t[n].addingReportingOverflow(carry)
                            t[n - 1] = sumN
                            t[n] = t[n + 1] &+ (overflowN ? 1 : 0)
                        }
                        // The result is below 2m: subtract m once when it is at least m.
                        var atLeastModulus = t[n] != 0
                        if !atLeastModulus {
                            atLeastModulus = true
                            for j in stride(from: n - 1, through: 0, by: -1) where t[j] != m[j] {
                                atLeastModulus = t[j] > m[j]
                                break
                            }
                        }
                        if atLeastModulus {
                            var borrow: UInt64 = 0
                            for j in 0 ..< n {
                                let (diff1, overflow1) = t[j].subtractingReportingOverflow(m[j])
                                let (diff2, overflow2) = diff1.subtractingReportingOverflow(borrow)
                                t[j] = diff2
                                borrow = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
                            }
                        }
                    }
                }
            }
        }
        t.removeLast(2)
        return t
    }

    /// base^exponent mod m; base must be below the modulus.
    func power(_ base: BigUInt, _ exponent: BigUInt) -> BigUInt {
        precondition(base < modulus)
        let baseForm = multiply(padded(base), rSquared)
        var result = multiply(padded(BigUInt(1)), rSquared)
        for index in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
            result = multiply(result, result)
            if exponent.bit(index) {
                result = multiply(result, baseForm)
            }
        }
        return BigUInt(limbs: multiply(result, padded(BigUInt(1))))
    }

    /// a·b mod m; both must be below the modulus.
    func product(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        BigUInt(limbs: multiply(multiply(padded(a), padded(b)), rSquared))
    }
}

enum TelegramCrypto {
    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return data
    }

    static func sha1(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func pbkdf2SHA512(password: Data, salt: Data, iterations: Int) -> Data {
        var derived = Data(count: 64)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), UInt32(iterations),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), 64,
                    )
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return derived
    }

    static func xor(_ a: Data, _ b: Data) -> Data {
        Data(zip(a, b).map { $0 ^ $1 })
    }

    /// AES-256 in IGE mode; `iv` is 32 bytes: the previous ciphertext block, then the previous plaintext block.
    static func ige(_ data: Data, key: Data, iv: Data, encrypt: Bool) -> Data {
        precondition(data.count % 16 == 0 && key.count == 32 && iv.count == 32)
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            CCCryptorCreate(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), keyBytes.baseAddress, 32, nil, &cryptor)
        }
        precondition(status == kCCSuccess, "CCCryptorCreate failed")
        defer { CCCryptorRelease(cryptor) }

        let input = [UInt8](data)
        var output = [UInt8](repeating: 0, count: input.count)
        var previousCipher = [UInt8](iv.prefix(16))
        var previousPlain = [UInt8](iv.suffix(16))
        var block = [UInt8](repeating: 0, count: 16)
        var processed = [UInt8](repeating: 0, count: 16)
        for start in stride(from: 0, to: input.count, by: 16) {
            for index in 0 ..< 16 {
                block[index] = input[start + index] ^ (encrypt ? previousCipher[index] : previousPlain[index])
            }
            var moved = 0
            CCCryptorUpdate(cryptor, block, 16, &processed, 16, &moved)
            for index in 0 ..< 16 {
                output[start + index] = processed[index] ^ (encrypt ? previousPlain[index] : previousCipher[index])
            }
            if encrypt {
                previousPlain = Array(input[start ..< start + 16])
                previousCipher = Array(output[start ..< start + 16])
            } else {
                previousCipher = Array(input[start ..< start + 16])
                previousPlain = Array(output[start ..< start + 16])
            }
        }
        return Data(output)
    }

    /// Splits MTProto's `pq`, a product of two primes below 2^32, with Pollard's rho (Brent's variant).
    static func factorize(_ pq: UInt64) -> (UInt64, UInt64) {
        if pq % 2 == 0 {
            return (2, pq / 2)
        }
        func mulmod(_ a: UInt64, _ b: UInt64) -> UInt64 {
            let product = a.multipliedFullWidth(by: b)
            return pq.dividingFullWidth(product).remainder
        }
        func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
            var (a, b) = (a, b)
            while b != 0 {
                (a, b) = (b, a % b)
            }
            return a
        }
        while true {
            var y = UInt64.random(in: 1 ..< pq)
            let c = UInt64.random(in: 1 ..< pq)
            let m: UInt64 = 128
            var g: UInt64 = 1, r: UInt64 = 1, q: UInt64 = 1
            var x: UInt64 = 0, ys: UInt64 = 0
            while g == 1 {
                x = y
                for _ in 0 ..< r {
                    y = (mulmod(y, y) &+ c) % pq
                }
                var k: UInt64 = 0
                while k < r, g == 1 {
                    ys = y
                    for _ in 0 ..< min(m, r - k) {
                        y = (mulmod(y, y) &+ c) % pq
                        q = mulmod(q, x > y ? x - y : y - x)
                    }
                    g = gcd(q, pq)
                    k += m
                }
                r *= 2
            }
            if g == pq {
                repeat {
                    ys = (mulmod(ys, ys) &+ c) % pq
                    g = gcd(x > ys ? x - ys : ys - x, pq)
                } while g == 1
            }
            if g != pq {
                let other = pq / g
                return (min(g, other), max(g, other))
            }
        }
    }

    /// Telegram's production RSA key (TDLib `PublicRsaKeySharedMain.cpp`), matched by fingerprint.
    static let rsaModulus = BigUInt(bytes: Data(hex: "e8bb3305c0b52c6cf2afdf7637313489e63e05268e5badb601af417786472e5f93b85438968e20e6729a301c0afc121bf7151f834436f7fda680847a66bf64accec78ee21c0b316f0edafe2f41908da7bd1f4a5107638eeb67040ace472a14f90d9f7c2b7def99688ba3073adb5750bb02964902a359fe745d8170e36876d4fd8a5d41b2a76cbff9a13267eb9580b2d06d10357448d20d9da2191cb5d8c93982961cdfdeda629e37f1fb09a0722027696032fe61ed663db7a37f6f263d370f69db53a0dc0a1748bdaaff6209d5645485e6e001d1953255757e4b8e42813347b11da6ab500fd0ace7e6dfa3736199ccaf9397ed0745a427dcfa6cd67bcb1acff3"))
    static let rsaExponent = BigUInt(65537)
    static let rsaFingerprint: Int64 = -3_414_540_481_677_951_611

    /// The 2048-bit safe prime Telegram uses for DH and SRP; any other is refused.
    static let dhPrime = BigUInt(bytes: Data(hex: "c71caeb9c6b1c9048e6c522f70f13f73980d40238e3e21c14934d037563d930f48198a0aa7c14058229493d22530f4dbfa336f6e0ac925139543aed44cce7c3720fd51f69458705ac68cd4fe6b6b13abdc9746512969328454f18faf8c595f642477fe96bb2a941d5bcd1d4ac8cc49880708fa9b378e3c4f3a9060bee67cf9a4a4a695811051907e162753b56b0f6b410dba74d8a84b2a14b3144e0ef1284754fd17ed950d5965b4b9dd46582db1178d169c6bc465b0d6ff9ca3928fef5b9ae4e418fc15e83ebea0f87fa9ff5eed70050ded2849f47bf959d956850ce929851f0d8115f635b105ee2e4e15d04b2454bf6f4fadf034b10403119cd8e3b92fcc5b"))

    /// RSA_PAD from the auth key exchange: pad to 192 bytes, reverse, hash with a temporary key,
    /// IGE-encrypt, then RSA-encrypt with the server's key.
    static func rsaPad(_ data: Data) -> Data {
        precondition(data.count <= 144)
        let padded = data + randomBytes(192 - data.count)
        let modulus = Montgomery(modulus: rsaModulus)
        while true {
            let tempKey = randomBytes(32)
            let dataWithHash = Data(padded.reversed()) + sha256(tempKey + padded)
            let aesEncrypted = ige(dataWithHash, key: tempKey, iv: Data(count: 32), encrypt: true)
            let keyAesEncrypted = BigUInt(bytes: xor(tempKey, sha256(aesEncrypted)) + aesEncrypted)
            guard keyAesEncrypted < rsaModulus else { continue }
            return modulus.power(keyAesEncrypted, rsaExponent).bytes(length: 256)
        }
    }

    /// `inputCheckPasswordSRP` values for a 2FA password and `account.password`'s
    /// `passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow` parameters.
    /// `secret` fixes the random exponent, for tests.
    static func srp(password: String, salt1: Data, salt2: Data, g: Int, p pBytes: Data, srpB: Data, secret: Data? = nil) throws -> (a: Data, m1: Data) {
        let p = BigUInt(bytes: pBytes)
        guard p == dhPrime else { throw TelegramError.protocolViolation("Unexpected SRP prime") }
        func sh(_ data: Data, _ salt: Data) -> Data {
            sha256(salt + data + salt)
        }
        let ph1 = sh(sh(Data(password.utf8), salt1), salt2)
        let ph2 = sh(pbkdf2SHA512(password: ph1, salt: salt1, iterations: 100_000), salt2)
        let x = BigUInt(bytes: ph2)
        let gBig = BigUInt(UInt64(g))
        let gPadded = gBig.bytes(length: 256)
        let pPadded = p.bytes(length: 256)
        let gB = BigUInt(bytes: srpB)
        guard !gB.isZero, gB < p else { throw TelegramError.protocolViolation("Bad SRP B") }
        let gBPadded = gB.bytes(length: 256)
        let mont = Montgomery(modulus: p)
        let k = BigUInt(bytes: sha256(pPadded + gPadded))
        let v = mont.power(gBig, x)
        var a = BigUInt()
        var gAPadded = Data()
        var u = BigUInt()
        repeat {
            a = BigUInt(bytes: secret ?? randomBytes(256))
            gAPadded = mont.power(gBig, a).bytes(length: 256)
            u = BigUInt(bytes: sha256(gAPadded + gBPadded))
        } while u.isZero
        let kv = mont.product(k, v)
        let t = gB >= kv ? gB - kv : gB + p - kv
        let sA = mont.power(t, a + u * x)
        let kA = sha256(sA.bytes(length: 256))
        let m1 = sha256(xor(sha256(pPadded), sha256(gPadded)) + sha256(salt1) + sha256(salt2) + gAPadded + gBPadded + kA)
        return (gAPadded, m1)
    }
}

extension Data {
    init(hex: String) {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        self = data
    }
}
