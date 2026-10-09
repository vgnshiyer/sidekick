import CryptoKit
import Foundation

/// What a notification says. `threadId` lets a tap open that thread.
public struct PushNotification: Codable, Sendable, Equatable {
    public var title: String
    public var body: String
    public var threadId: String
    /// Delivered at high urgency (a thread waiting on the user).
    public var urgent: Bool

    public init(title: String, body: String, threadId: String, urgent: Bool) {
        self.title = title
        self.body = body
        self.threadId = threadId
        self.urgent = urgent
    }
}

/// Web Push (RFC 8030): message encryption (RFC 8291, aes128gcm) and VAPID (RFC 8292).
/// The push service (Apple's, for an iPhone home-screen app) only ever sees ciphertext.
public enum WebPush {
    /// A browser's push subscription, as `PushSubscription.toJSON()` gives it.
    public struct Subscription: Codable, Equatable, Sendable {
        public struct Keys: Codable, Equatable, Sendable {
            public let p256dh: String
            public let auth: String
        }

        public let endpoint: String
        public let keys: Keys

        /// Only real push services over HTTPS, so the page can't point the Mac at arbitrary hosts.
        public var isAllowedEndpoint: Bool {
            guard let url = URL(string: endpoint), url.scheme == "https", let host = url.host?.lowercased() else { return false }
            return ["push.apple.com", "fcm.googleapis.com", "push.services.mozilla.com", "notify.windows.com"]
                .contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    enum Failure: Error, Equatable {
        case badKeys
        case badEndpoint
    }

    /// The body for one subscription: header (salt, record size, sender key) then one AES-128-GCM record.
    static func encrypt(
        _ payload: Data, uaPublic: Data, authSecret: Data,
        asPrivate: P256.KeyAgreement.PrivateKey = .init(), salt: Data = randomBytes(16)
    ) throws -> Data {
        guard let uaKey = try? P256.KeyAgreement.PublicKey(x963Representation: uaPublic), authSecret.count == 16
        else { throw Failure.badKeys }
        let asPublic = asPrivate.publicKey.x963Representation
        let shared = try asPrivate.sharedSecretFromKeyAgreement(with: uaKey)
        let ikm = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: authSecret, sharedInfo: Data("WebPush: info\0".utf8) + uaPublic + asPublic,
            outputByteCount: 32)
        let cek = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
        // A single record: the payload, then the 0x02 "last record" delimiter.
        let sealed = try AES.GCM.seal(
            payload + Data([2]), using: cek, nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }))

        var body = salt
        body.append(contentsOf: withUnsafeBytes(of: UInt32(4096).bigEndian) { Array($0) })
        body.append(UInt8(asPublic.count))
        body.append(asPublic)
        return body + sealed.ciphertext + sealed.tag
    }

    /// `Authorization: vapid t=<JWT>, k=<public key>` for the endpoint's origin, valid for under an hour.
    static func vapid(endpoint: URL, key: P256.Signing.PrivateKey, subject: String, now: Date = Date()) throws -> String {
        guard let scheme = endpoint.scheme, let host = endpoint.host else { throw Failure.badEndpoint }
        let audience = "\(scheme)://\(host)" + (endpoint.port.map { ":\($0)" } ?? "")
        let claims: [String: Any] = ["aud": audience, "exp": Int(now.timeIntervalSince1970) + 55 * 60, "sub": subject]
        let input = base64url(Data(#"{"typ":"JWT","alg":"ES256"}"#.utf8)) + "."
            + base64url(try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
        let signature = try key.signature(for: Data(input.utf8)).rawRepresentation
        return "vapid t=\(input).\(base64url(signature)), k=\(base64url(key.publicKey.x963Representation))"
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64urlDecode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }
}

/// The Mac's side of phone notifications: its VAPID key, the phones that subscribed, and sending.
/// Both live in `directory` (0600): `push-vapid.key` and `push-subscriptions.json`.
public actor PushCenter {
    private let directory: URL
    private let key: P256.Signing.PrivateKey
    private let session: URLSession
    private var subscriptions: [WebPush.Subscription]

    /// VAPID's contact claim; push services may use it to reach the sender.
    static let subject = "https://github.com/vgnshiyer/sidekick"

    /// The VAPID public key the page subscribes with (base64url, uncompressed point).
    public nonisolated let publicKey: String

    public init(directory: URL, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
        let keyFile = directory.appendingPathComponent("push-vapid.key")
        if let raw = try? Data(contentsOf: keyFile), let saved = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            key = saved
        } else {
            key = P256.Signing.PrivateKey()
            FileManager.default.createFile(
                atPath: keyFile.path, contents: key.rawRepresentation, attributes: [.posixPermissions: 0o600])
        }
        publicKey = WebPush.base64url(key.publicKey.x963Representation)
        let file = directory.appendingPathComponent("push-subscriptions.json")
        subscriptions = (try? JSONDecoder().decode([WebPush.Subscription].self, from: Data(contentsOf: file))) ?? []
    }

    public var hasSubscribers: Bool { !subscriptions.isEmpty }

    /// Remember a phone; returns false for an endpoint that isn't a known push service.
    @discardableResult
    public func subscribe(_ subscription: WebPush.Subscription) -> Bool {
        guard subscription.isAllowedEndpoint else { return false }
        subscriptions.removeAll { $0.endpoint == subscription.endpoint }
        subscriptions.append(subscription)
        save()
        return true
    }

    public func unsubscribe(endpoint: String) {
        subscriptions.removeAll { $0.endpoint == endpoint }
        save()
    }

    /// Send to every subscribed phone; drops subscriptions the push service says are gone.
    /// Returns how many accepted it.
    @discardableResult
    public func send(_ notification: PushNotification) async -> Int {
        guard let payload = try? JSONEncoder().encode(notification) else { return 0 }
        var delivered = 0
        for subscription in subscriptions {
            switch await deliver(payload, to: subscription, urgent: notification.urgent) {
            case .ok: delivered += 1
            case .gone: unsubscribe(endpoint: subscription.endpoint)
            case .failed: break
            }
        }
        return delivered
    }

    private enum Result { case ok, gone, failed }

    private func deliver(_ payload: Data, to subscription: WebPush.Subscription, urgent: Bool) async -> Result {
        guard let url = URL(string: subscription.endpoint),
              let uaPublic = WebPush.base64urlDecode(subscription.keys.p256dh),
              let auth = WebPush.base64urlDecode(subscription.keys.auth),
              let body = try? WebPush.encrypt(payload, uaPublic: uaPublic, authSecret: auth),
              let authorization = try? WebPush.vapid(endpoint: url, key: key, subject: Self.subject)
        else { return .failed }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("86400", forHTTPHeaderField: "TTL")
        request.setValue(urgent ? "high" : "normal", forHTTPHeaderField: "Urgency")
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse
        else { return .failed }
        switch http.statusCode {
        case 200..<300: return .ok
        case 404, 410: return .gone
        default: return .failed
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(subscriptions) else { return }
        let file = directory.appendingPathComponent("push-subscriptions.json")
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
