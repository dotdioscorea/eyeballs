import AuthenticationServices
import UIKit

@MainActor
final class KimiBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var pending: CheckedContinuation<AccountCredential, Error>?
    private var poller: Task<Void, Never>?
    func signIn(previous: AccountCredential?, privateSession: Bool, region: KimiAuth.Region) async throws -> AccountCredential {
        let attempt = try await KimiAuth.begin(region: previous.flatMap { try? KimiAuth.Region.matching($0.issuer) } ?? region, hostID: previous?.hostID ?? UUID().uuidString)
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending in
                self.pending = pending
                let session = ASWebAuthenticationSession(url: attempt.url, callbackURLScheme: nil) { [weak self] _, _ in
                    Task { @MainActor in self?.finish(.failure(AuthError.cancelled)) }
                }
                self.session = session; session.presentationContextProvider = self; session.prefersEphemeralWebBrowserSession = privateSession
                guard session.start() else { finish(.failure(AuthError.unavailable)); return }
                poller = Task { [weak self] in
                    var interval = attempt.interval
                    do {
                        while Date.now < attempt.expiresAt {
                            try await Task.sleep(for: .seconds(interval))
                            switch try await KimiAuth.poll(attempt) {
                            case .pending: continue
                            case .slowDown: interval += 5
                            case .tokens(let raw):
                                let credential = try await KimiAuth.credential(raw, region: attempt.region, hostID: attempt.hostID, previous: previous)
                                try Task.checkCancellation(); self?.finish(.success(credential)); return
                            }
                        }
                        self?.finish(.failure(AuthError.timedOut))
                    } catch is CancellationError { }
                    catch { self?.finish(.failure(error)) }
                }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    func cancel() { finish(.failure(AuthError.cancelled)) }
    private func finish(_ result: Result<AccountCredential, Error>) {
        guard let pending else { return }
        self.pending = nil; poller?.cancel(); poller = nil; session?.cancel(); session = nil; pending.resume(with: result)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
