import AuthenticationServices
import UIKit

@MainActor
final class CopilotBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var pending: CheckedContinuation<AccountCredential, Error>?
    private var poller: Task<Void, Never>?
    private var verification: CopilotAuth.Verification?
    private var previous: AccountCredential?
    private var privateSession = false
    func signIn(previous: AccountCredential?, privateSession: Bool, showCode: @escaping (String) -> Void) async throws -> AccountCredential {
        let verification = try await CopilotAuth.begin()
        try Task.checkCancellation()
        self.verification = verification; self.previous = previous; self.privateSession = privateSession
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending in
                self.pending = pending
                showCode(verification.userCode)
                poller = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(max(0, verification.expiresAt.timeIntervalSinceNow)))
                        self?.finish(.failure(AuthError.timedOut))
                    } catch { }
                }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    func open() {
        guard let verification, pending != nil, session == nil else { return }
        // GitHub deliberately requires code entry. Copy only when explicitly tapped.
        UIPasteboard.general.setItems([["public.utf8-plain-text": verification.userCode]], options: [.localOnly: true, .expirationDate: verification.expiresAt])
        let session = ASWebAuthenticationSession(url: verification.url, callbackURLScheme: nil) { [weak self] _, _ in
            Task { @MainActor in self?.finish(.failure(AuthError.cancelled)) }
        }
        self.session = session; session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = privateSession
        guard session.start() else { finish(.failure(AuthError.unavailable)); return }
        poller?.cancel()
        poller = Task { [weak self] in
            var interval = verification.interval
            do {
                while Date.now < verification.expiresAt {
                    try await Task.sleep(for: .seconds(interval))
                    switch try await CopilotAuth.poll(verification) {
                    case .pending: continue
                    case .slowDown: interval += 5
                    case .token(let raw):
                        let credential = try await CopilotAuth.credential(raw, previous: self?.previous)
                        try Task.checkCancellation()
                        self?.finish(.success(credential)); return
                    }
                }
                self?.finish(.failure(AuthError.timedOut))
            } catch is CancellationError { }
            catch { self?.finish(.failure(error)) }
        }
    }
    func cancel() { finish(.failure(AuthError.cancelled)) }
    private func finish(_ result: Result<AccountCredential, Error>) {
        guard let pending else { return }
        self.pending = nil
        poller?.cancel(); poller = nil; verification = nil; previous = nil
        session?.cancel(); session = nil
        pending.resume(with: result)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
