//
//  AuthViewModel.swift
//  WorkSurvivalGuide
//
//  登录/注册 ViewModel：支持邮箱+密码、Apple Sign In
//

import Foundation
import AuthenticationServices
import TikTokBusinessSDK
import KochavaMeasurement
import GoogleSignIn

@MainActor
class AuthViewModel: ObservableObject {
    @Published var email: String = ""
    @Published var password: String = ""
    @Published var confirmPassword: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var emailLoginEnabled: Bool = true

    func loadAppConfig() {
        _Concurrency.Task { emailLoginEnabled = await NetworkManager.shared.getAppConfig() }
    }

    // MARK: - Email Sign In (login + auto-register)

    func emailSignIn() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            showAuthError("Please enter your email address")
            return
        }
        guard password.count >= 8 else {
            showAuthError("Password must be at least 8 characters")
            return
        }

        isLoading = true
        errorMessage = nil

        _Concurrency.Task {
            do {
                _ = try await AuthService.shared.emailLogin(email: trimmedEmail, password: password)
                let userInfo = try await AuthService.shared.getCurrentUser()
                isLoading = false
                AuthManager.shared.loginSuccess(userInfo: userInfo)
                TikTokTracker.track("Login", ["method": "email"])
                TikTokBusiness.identify(withExternalID: userInfo.user_id, externalUserName: nil, phoneNumber: nil, email: userInfo.email)
                // Kochava IdentityLink：只传内部用户 ID，不传 PII
                IdentityLink.register(name: "User ID", identifier: userInfo.user_id)
            } catch {
                isLoading = false
                showAuthError(error.localizedDescription)
            }
        }
    }

    // MARK: - Email Register (explicit register with confirm password)

    func emailRegister() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            showAuthError("Please enter your email address")
            return
        }
        guard password.count >= 8 else {
            showAuthError("Password must be at least 8 characters")
            return
        }
        guard password == confirmPassword else {
            showAuthError("Passwords do not match")
            return
        }

        isLoading = true
        errorMessage = nil

        _Concurrency.Task {
            do {
                let loginData = try await AuthService.shared.emailLogin(email: trimmedEmail, password: password)
                let userInfo = try await AuthService.shared.getCurrentUser()
                isLoading = false
                AuthManager.shared.loginSuccess(userInfo: userInfo)
                if loginData.is_new_user == true {
                    TikTokTracker.track("Registration", ["method": "email"])
                }
                TikTokTracker.track("Login", ["method": "email"])
                TikTokBusiness.identify(withExternalID: userInfo.user_id, externalUserName: nil, phoneNumber: nil, email: userInfo.email)
                IdentityLink.register(name: "User ID", identifier: userInfo.user_id)
            } catch {
                isLoading = false
                showAuthError(error.localizedDescription)
            }
        }
    }

    // MARK: - Apple Sign In

    func handleAppleSignIn(result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8),
                  let codeData = credential.authorizationCode,
                  let authCode = String(data: codeData, encoding: .utf8) else {
                showAuthError("Apple Sign In failed: missing credentials")
                return
            }

            let fullName: String? = {
                guard let name = credential.fullName else { return nil }
                let parts = [name.givenName, name.familyName].compactMap { $0 }
                return parts.isEmpty ? nil : parts.joined(separator: " ")
            }()

            isLoading = true
            errorMessage = nil

            _Concurrency.Task {
                do {
                    let loginData = try await AuthService.shared.appleLogin(
                        identityToken: identityToken,
                        authCode: authCode,
                        fullName: fullName
                    )
                    let userInfo = try await AuthService.shared.getCurrentUser()
                    isLoading = false
                    AuthManager.shared.loginSuccess(userInfo: userInfo)
                    if loginData.is_new_user == true {
                        TikTokTracker.track("Registration", ["method": "apple"])
                    }
                    TikTokTracker.track("Login", ["method": "apple"])
                    TikTokBusiness.identify(withExternalID: userInfo.user_id, externalUserName: nil, phoneNumber: nil, email: userInfo.email)
                    IdentityLink.register(name: "User ID", identifier: userInfo.user_id)
                } catch {
                    isLoading = false
                    showAuthError(error.localizedDescription)
                }
            }

        case .failure(let error):
            // 用户主动取消不显示错误
            let nsErr = error as NSError
            if nsErr.code != ASAuthorizationError.canceled.rawValue {
                showAuthError("Apple Sign In failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Google Sign In

    func handleGoogleSignIn() {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            showAuthError("Cannot present Google Sign In")
            return
        }

        isLoading = true
        errorMessage = nil

        GIDSignIn.sharedInstance.signIn(withPresenting: rootVC) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                self.isLoading = false
                let nsErr = error as NSError
                if nsErr.code != GIDSignInError.canceled.rawValue {
                    self.showAuthError("Google Sign In failed: \(error.localizedDescription)")
                }
                return
            }

            guard let idToken = result?.user.idToken?.tokenString else {
                self.isLoading = false
                self.showAuthError("Google Sign In failed: missing credentials")
                return
            }

            _Concurrency.Task {
                do {
                    let loginData = try await AuthService.shared.googleLogin(idToken: idToken)
                    let userInfo = try await AuthService.shared.getCurrentUser()
                    self.isLoading = false
                    AuthManager.shared.loginSuccess(userInfo: userInfo)
                    if loginData.is_new_user == true {
                        TikTokTracker.track("Registration", ["method": "google"])
                    }
                    TikTokTracker.track("Login", ["method": "google"])
                    TikTokBusiness.identify(withExternalID: userInfo.user_id, externalUserName: nil, phoneNumber: nil, email: userInfo.email)
                    IdentityLink.register(name: "User ID", identifier: userInfo.user_id)
                } catch {
                    self.isLoading = false
                    self.showAuthError(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Private

    private func showAuthError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
