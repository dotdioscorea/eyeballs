import AuthenticationServices
import UIKit

@MainActor
final class CursorBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var pending: CheckedContinuation<AccountCredential, Error>?
    private var poller: Task<Void, Never>?
    func signIn(previous: AccountCredential?, privateSession: Bool) async throws -> AccountCredential {
        try Task.checkCancellation()
        let attempt = try CursorAuth.Attempt()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending in
                self.pending = pending
                let session = ASWebAuthenticationSession(url: attempt.url, callbackURLScheme: nil) { [weak self] _, _ in
                    Task { @MainActor in self?.finish(.failure(AuthError.cancelled)) }
                }
                self.session = session; session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = privateSession
                guard session.start() else { finish(.failure(AuthError.unavailable)); return }
                poller = Task { [weak self] in
                    do {
                        var interval = 1.0
                        while Date.now < attempt.expiresAt {
                            try await Task.sleep(for: .seconds(interval))
                            if let raw = try await CursorAuth.poll(attempt) {
                                let credential = try await CursorAuth.credential(raw, attempt: attempt, previous: previous)
                                try Task.checkCancellation()
                                self?.finish(.success(credential)); return
                            }
                            interval = min(10, interval * 1.2)
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
        self.pending = nil; poller?.cancel(); poller = nil
        session?.cancel(); session = nil
        pending.resume(with: result)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
