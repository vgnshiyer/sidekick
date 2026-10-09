import CryptoKit
import Foundation
import XCTest
@testable import BridgeKit

final class WebPushTests: XCTestCase {
    private func b64(_ text: String) -> Data { WebPush.base64urlDecode(text)! }

    /// RFC 8291 appendix A: the fixed keys and salt must give exactly the published body.
    func testEncryptionMatchesRFC8291Example() throws {
        let asPrivate = try P256.KeyAgreement.PrivateKey(rawRepresentation: b64("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"))
        let body = try WebPush.encrypt(
            Data("When I grow up, I want to be a watermelon".utf8),
            uaPublic: b64("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"),
            authSecret: b64("BTBZMqHH6r4Tts7J_aSIgg"),
            asPrivate: asPrivate,
            salt: b64("DGv6ra1nlYgDCS1FRnbzlw"))
        XCTAssertEqual(
            WebPush.base64url(body),
            "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN")
    }

    func testBadSubscriptionKeysAreRejected() {
        XCTAssertThrowsError(try WebPush.encrypt(Data("x".utf8), uaPublic: Data([1, 2, 3]), authSecret: Data(count: 16)))
    }

    func testVapidHeaderIsASignedJWTForTheEndpointOrigin() throws {
        let key = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let header = try WebPush.vapid(
            endpoint: URL(string: "https://web.push.apple.com/QK2v8YmF")!, key: key, subject: "https://example.com", now: now)
        XCTAssertTrue(header.hasPrefix("vapid t="))
        let parts = header.dropFirst("vapid t=".count).components(separatedBy: ", k=")
        XCTAssertEqual(parts[1], WebPush.base64url(key.publicKey.x963Representation))
        let jwt = parts[0].split(separator: ".").map(String.init)
        XCTAssertEqual(jwt.count, 3)
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: b64(jwt[1])) as? [String: Any])
        XCTAssertEqual(claims["aud"] as? String, "https://web.push.apple.com")
        XCTAssertEqual(claims["sub"] as? String, "https://example.com")
        let exp = try XCTUnwrap(claims["exp"] as? Int)
        XCTAssertGreaterThan(exp, Int(now.timeIntervalSince1970))
        XCTAssertLessThanOrEqual(exp, Int(now.timeIntervalSince1970) + 3600)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: b64(jwt[2]))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data((jwt[0] + "." + jwt[1]).utf8)))
    }

    func testOnlyPushServiceEndpointsAreAccepted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("push-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let center = PushCenter(directory: directory)
        let keys = WebPush.Subscription.Keys(p256dh: "x", auth: "y")
        let apple = await center.subscribe(.init(endpoint: "https://web.push.apple.com/abc", keys: keys))
        let plain = await center.subscribe(.init(endpoint: "http://web.push.apple.com/abc", keys: keys))
        let local = await center.subscribe(.init(endpoint: "https://192.168.1.1/admin", keys: keys))
        let lookalike = await center.subscribe(.init(endpoint: "https://evilpush.apple.com.example.org/x", keys: keys))
        XCTAssertEqual([apple, plain, local, lookalike], [true, false, false, false])

        // The key and the subscription survive a restart.
        let again = PushCenter(directory: directory)
        XCTAssertEqual(again.publicKey, center.publicKey)
        let has = await again.hasSubscribers
        XCTAssertTrue(has)
    }
}
