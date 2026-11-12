//
//  Passkeys.swift — вход по ключам доступа (passkeys). Паритет Android (core/Passkeys.kt).
//  Контракт: ответ сайта на П-71 п.5. Домен: webcredentials:yumurta.ru (project.yml).
//  Бинарные поля — base64url без «=». Клиент декодирует convertFromSnakeCase, а тело
//  credential уходит через JSONSerialization (postJSON): иначе encoder с
//  convertToSnakeCase испортил бы rawId / clientDataJSON.
//

import AuthenticationServices
import UIKit

enum PasskeyOutcome<T> {
    case ok(T)
    case cancelled          // человек закрыл окно — молчим
    case fail(String)
}

struct PasskeyItem: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let createdAt: String
    let lastUsedAt: String?

    private enum K: String, CodingKey { case id, name, createdAt, lastUsedAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decode(LenientInt.self, forKey: .id))?.wrappedValue ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
        lastUsedAt = try? c.decodeIfPresent(String.self, forKey: .lastUsedAt)
    }
}

private struct PasskeyUserBody: Decodable {
    let id: String
    let name: String?
}
private struct PasskeyOptionsBody: Decodable {
    let challenge: String
    let user: PasskeyUserBody?
}
private struct PasskeyOptionsResponse: Decodable {
    let challengeId: String
    let options: PasskeyOptionsBody
}

extension Data {
    /// base64url без «=».
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}

/// Обёртка над ASAuthorizationController: один запрос — одно async-ожидание.
@MainActor
private final class PasskeyCoordinator: NSObject, ASAuthorizationControllerDelegate,
                                        ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var controller: ASAuthorizationController?

    func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let c = ASAuthorizationController(authorizationRequests: [request])
            c.delegate = self
            c.presentationContextProvider = self
            controller = c
            c.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization); continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        return scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first ?? ASPresentationAnchor()
    }
}

enum Passkeys {
    static let rpId = "yumurta.ru"
    static let unsupported = "Телефон не поддерживает ключи доступа"
    private static let generic = "Не удалось использовать ключ доступа. Попробуйте ещё раз или войдите по номеру телефона"

    /// Имя нового ключа по умолчанию — тип устройства («iPhone» / «iPad»).
    @MainActor static var defaultName: String { UIDevice.current.model }

    /// «2026-11-11 14:30:00» → «11.11.2026».
    static func humanDate(_ raw: String?) -> String {
        guard let raw, let r = raw.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return raw ?? "" }
        let p = raw[r].split(separator: "-")
        return p.count == 3 ? "\(p[2]).\(p[1]).\(p[0])" : String(raw[r])
    }

    private static func message(_ error: Error) -> String {
        if let e = error as? APIError, e.errorCode == "passkey_unknown" {
            return "Ключ удалён — войдите по номеру телефона"
        }
        let m = error.localizedDescription
        return m.isEmpty ? generic : m
    }

    private static func isExpired(_ error: Error) -> Bool {
        (error as? APIError)?.errorCode == "challenge_expired"
    }

    /// nil — отмена; иначе текст ошибки системы.
    private static func systemFailure(_ error: Error) -> String? {
        if let e = error as? ASAuthorizationError, e.code == .canceled { return nil }
        if error is CancellationError { return nil }
        return generic
    }

    // MARK: Вход

    /// `consentAt` — время отметки согласия на ПД (П-74 п.4), уходит в passkey/login/verify.
    @MainActor
    static func signIn(consentAt: String? = nil) async -> PasskeyOutcome<AuthTokens> {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let o: PasskeyOptionsResponse = try await API.shared.postJSON("api/v1/auth/passkey/login/options", json: [:])
                guard let challenge = Data(base64URL: o.options.challenge) else { return .fail(generic) }
                let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
                let req = provider.createCredentialAssertionRequest(challenge: challenge)
                req.userVerificationPreference = .required   // сервер требует userVerification: required
                let coord = PasskeyCoordinator()
                let auth: ASAuthorization
                do { auth = try await coord.perform(req) }
                catch {
                    if let m = systemFailure(error) { return .fail(m) }
                    return .cancelled
                }
                guard let a = auth.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
                    return .fail(generic)
                }
                let cred: [String: Any] = [
                    "id": a.credentialID.base64URL,
                    "rawId": a.credentialID.base64URL,
                    "type": "public-key",
                    "response": [
                        "clientDataJSON": a.rawClientDataJSON.base64URL,
                        "authenticatorData": a.rawAuthenticatorData.base64URL,
                        "signature": a.signature.base64URL,
                        "userHandle": a.userID.base64URL,
                    ] as [String: Any],
                ]
                var json: [String: Any] = ["challenge_id": o.challengeId, "credential": cred]
                if let at = consentAt { json.merge(PdConsent.fields(at)) { _, new in new } }
                let tokens: AuthTokens = try await API.shared.postJSON(
                    "api/v1/auth/passkey/login/verify",
                    json: json)
                return .ok(tokens)
            } catch {
                if isExpired(error) && attempt < 2 { continue }
                if error is CancellationError { return .cancelled }
                return .fail(message(error))
            }
        }
    }

    // MARK: Создание ключа (нужен вход в аккаунт)

    @MainActor
    static func register(name: String) async -> PasskeyOutcome<PasskeyItem> {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let o: PasskeyOptionsResponse = try await API.shared.postJSON("api/v1/auth/passkey/register/options", json: [:])
                guard let challenge = Data(base64URL: o.options.challenge),
                      let userId = o.options.user.flatMap({ Data(base64URL: $0.id) }) else { return .fail(generic) }
                let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
                let accountName = o.options.user?.name ?? name
                let req = provider.createCredentialRegistrationRequest(challenge: challenge, name: accountName, userID: userId)
                req.userVerificationPreference = .required
                let coord = PasskeyCoordinator()
                let auth: ASAuthorization
                do { auth = try await coord.perform(req) }
                catch {
                    if let m = systemFailure(error) { return .fail(m) }
                    return .cancelled
                }
                guard let r = auth.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
                      let attestation = r.rawAttestationObject else { return .fail(generic) }
                let cred: [String: Any] = [
                    "id": r.credentialID.base64URL,
                    "rawId": r.credentialID.base64URL,
                    "type": "public-key",
                    "response": [
                        "clientDataJSON": r.rawClientDataJSON.base64URL,
                        "attestationObject": attestation.base64URL,
                    ] as [String: Any],
                ]
                var body: [String: Any] = ["challenge_id": o.challengeId, "credential": cred]
                let n = name.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { body["name"] = n }
                let item: PasskeyItem = try await API.shared.postJSON("api/v1/auth/passkey/register/verify", json: body)
                return .ok(item)
            } catch {
                if isExpired(error) && attempt < 2 { continue }
                if error is CancellationError { return .cancelled }
                return .fail(message(error))
            }
        }
    }

    static func list() async throws -> [PasskeyItem] {
        try await API.shared.get("api/v1/auth/passkeys", fresh: true)
    }

    static func delete(_ id: Int) async throws {
        try await API.shared.deleteVoid("api/v1/auth/passkeys/\(id)")
    }
}
