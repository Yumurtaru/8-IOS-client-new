//
//  SocialLogin.swift
//  Вход через соцсети (RFC 8252 + PKCE, ответ на П-83 п.5).
//
//  GET  api/v1/auth/social/config            → {providers:[{id, name, start_url}]}
//  Браузер: {start_url}?app=client&challenge=…&return=yumurta://oauth (ASWebAuthenticationSession)
//  Возврат: yumurta://oauth?ticket=… | ?error=denied|failed — приходит в completionHandler.
//  POST api/v1/auth/social/ticket {ticket, verifier} → как обычный вход ({user, token, refresh}).
//

import Foundation
import AuthenticationServices
import CryptoKit
import Security   // SecRandomCopyBytes — явно, как в TokenStore/CardSecret
import UIKit

/// Кнопка входа от сервера. Все поля необязательные: старый сервер не ломает разбор.
struct SocialProvider: Decodable {
    let id: String?
    let name: String?
    let startUrl: String?
    var stableId: String { id ?? name ?? "" }
    var isUsable: Bool { !(id ?? "").isEmpty && !(name ?? "").isEmpty && !(startUrl ?? "").isEmpty }
}

struct SocialConfig: Decodable {
    let providers: [SocialProvider]?
}

/// Чистая логика: PKCE, адрес старта, разбор возврата.
enum SocialPkce {
    static let returnURL = "yumurta://oauth"
    static let textDenied = "Вход отменён"
    static let textFailed = "Не удалось войти, попробуйте ещё раз"
    static let textTicket = "Вход не удался — попробуйте ещё раз"

    static func base64Url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 32 случайных байта → base64url без «=» (43 знака).
    static func newVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return base64Url(Data(bytes))
    }

    static func challenge(_ verifier: String) -> String {
        base64Url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func startURL(_ startUrl: String, challenge: String) -> URL? {
        let sep = startUrl.contains("?") ? "&" : "?"
        return URL(string: startUrl + sep + "app=client&challenge=" + challenge + "&return=" + returnURL)
    }

    enum Result: Equatable {
        case ticket(String)
        case denied
        case failed
    }

    static func parse(_ url: URL) -> Result {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ k: String) -> String { (items.first { $0.name == k }?.value ?? "").trimmingCharacters(in: .whitespaces) }
        let e = v("error").lowercased()
        if !e.isEmpty { return e == "denied" ? .denied : .failed }
        let t = v("ticket")
        return (!t.isEmpty && t.count <= 200) ? .ticket(t) : .failed
    }
}

/// Одна сессия входа: ASWebAuthenticationSession + verifier в памяти (сессия живёт в том же процессе).
@MainActor
final class SocialLoginSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Outcome {
        case ticket(String, verifier: String)
        case denied
        case failed
        case cancelled
    }

    private var session: ASWebAuthenticationSession?
    private(set) var active = false

    func start(_ provider: SocialProvider) async -> Outcome {
        // Двойное нажатие — одна сессия.
        guard !active, let base = provider.startUrl else { return .cancelled }
        let verifier = SocialPkce.newVerifier()
        guard let url = SocialPkce.startURL(base, challenge: SocialPkce.challenge(verifier)) else { return .failed }
        active = true
        defer { active = false; session = nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "yumurta") { callback, error in
                if let callback {
                    switch SocialPkce.parse(callback) {
                    case .ticket(let t): cont.resume(returning: .ticket(t, verifier: verifier))
                    case .denied: cont.resume(returning: .denied)
                    case .failed: cont.resume(returning: .failed)
                    }
                } else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    cont.resume(returning: .cancelled)
                } else {
                    cont.resume(returning: .failed)
                }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            if !s.start() { cont.resume(returning: .failed) }
        }
    }

    /// Уход с экрана — отмена (completionHandler придёт с canceledLogin).
    func cancel() { session?.cancel() }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        return scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first ?? ASPresentationAnchor()
    }
}
