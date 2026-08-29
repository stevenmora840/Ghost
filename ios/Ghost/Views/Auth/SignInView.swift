import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @EnvironmentObject var app: AppState
    @State private var email = ""
    @State private var password = ""
    @State private var isRegistering = false
    @State private var isBusy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accent)
                Text("Ghost")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Private by design")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(14)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.border))

                SecureField("Password", text: $password)
                    .textContentType(isRegistering ? .newPassword : .password)
                    .padding(14)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.border))

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await submit() }
                } label: {
                    Group {
                        if isBusy {
                            ProgressView().tint(Theme.background)
                        } else {
                            Text(isRegistering ? "Create account" : "Sign in")
                                .font(.system(size: 16, weight: .bold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .background(Theme.accent)
                .foregroundStyle(Theme.background)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .disabled(isBusy || email.isEmpty || password.isEmpty)

                Button(isRegistering ? "Have an account? Sign in" : "New here? Create an account") {
                    isRegistering.toggle()
                    error = nil
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            }

            HStack {
                Rectangle().fill(Theme.border).frame(height: 1)
                Text("or").font(.footnote).foregroundStyle(Theme.textMuted)
                Rectangle().fill(Theme.border).frame(height: 1)
            }

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.email]
            } onCompletion: { result in
                Task { await handleApple(result) }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))

            Spacer()
        }
        .padding(24)
        .background(Theme.background)
    }

    private func submit() async {
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            let pair = isRegistering
                ? try await app.api.register(email: email, password: password)
                : try await app.api.login(email: email, password: password)
            app.signIn(with: pair)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) async {
        guard case let .success(authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8)
        else {
            if case let .failure(err) = result, (err as? ASAuthorizationError)?.code != .canceled {
                error = err.localizedDescription
            }
            return
        }
        do {
            let pair = try await app.api.signInWithApple(identityToken: token)
            app.signIn(with: pair)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
