//
//  AuthContainer.swift
//  Authgear-iOS
//
//  Created by Peter Cheng on 26/8/2020.
//

import Foundation
import AuthenticationServices
import SafariServices

public typealias AuthorizeCompletionHandler = (Result<AuthorizeResponse, Error>) -> Void
public typealias VoidCompletionHandler = (Result<Void, Error>
) -> Void

internal protocol BaseContainer {
    var name: String { get }
    var clientId: String! { get set }
    var apiClient: AuthAPIClient { get }
    var storage: ContainerStorage { get }

    func configure(clientId: String, endpoint: String)
    func authorize(
        redirectURI: String,
        state: String?,
        prompt: String?,
        loginHint: String?,
        uiLocales: [String]?,
        handler: @escaping AuthorizeCompletionHandler
    )
    func authenticateAnonymously(
        handler: @escaping AuthorizeCompletionHandler
    )
    func promoteAnonymousUser(
        redirectURI: String,
        state: String?,
        uiLocales: [String]?,
        handler: @escaping AuthorizeCompletionHandler
    )
    func logout(
        force: Bool,
        redirectURI: String?,
        handler: @escaping (Result<Void, Error>) -> Void
    )
}


public struct AuthorizeOptions {
    let redirectURI: String
    let state: String?
    let prompt: String?
    let loginHint: String?
    let uiLocales: [String]?

    var urlScheme: String {

        if let index = redirectURI.firstIndex(of: ":") {
            return String(redirectURI[..<index])
        }
        return redirectURI
    }

    public init(
        redirectURI: String,
        state: String? = nil,
        prompt: String? = nil,
        loginHint: String? = nil,
        uiLocales: [String]? = nil
    ) {
        self.redirectURI = redirectURI
        self.state = state
        self.prompt = prompt
        self.loginHint = loginHint
        self.uiLocales = uiLocales
    }
}

public struct UserInfo: Decodable {

    enum CodingKeys: String, CodingKey {
        case isAnonymous = "https://authgear.com/user/is_anonymous"
        case isVerified = "https://authgear.com/user/is_verified"
        case iss
        case sub
    }

    let isAnonymous: Bool
    let isVerified: Bool
    let iss: String
    let sub: String
}

public struct AuthorizeResponse {
    public let userInfo: UserInfo
    public let state: String?
}

public protocol AuthContainerDelegate: class {
    func onRefreshTokenExpired()
}

public class AuthContainer: NSObject, BaseContainer {
    internal let name: String
    internal let apiClient: AuthAPIClient
    internal let storage: ContainerStorage
    internal var clientId: String!

    private let isThirdParty = true

    private let authenticationSessionProvider = AuthenticationSessionProvider()
    private var authenticationSession: AuthenticationSession?

    private var accessToken: String?
    private var refreshToken: String?
    private var expireAt: Date?

    private let jwkStore = JWKStore()

    public weak var delegate: AuthContainerDelegate?

    public init(name: String? = nil) {
        self.name = name ?? "default"
        self.apiClient = DefaultAuthAPIClient()
        self.storage = DefaultContainerStorage(storageDriver: KeychainStorageDriver())
    }

    public func configure(clientId: String, endpoint: String) {
        self.configure(clientId: clientId, endpoint: endpoint, handler: nil)
    }

    public func configure(
        clientId: String,
        endpoint: String,
        handler: VoidCompletionHandler? = nil) {
        self.clientId = clientId
        self.apiClient.endpoint = URL(string: endpoint)

        self.refreshToken = try? self.storage.getRefreshToken(namespace: self.name)

        if self.shouldRefreshAccessToken() {
            self.refreshAccessToken(handler: handler)
        }
    }

    private func authorizeEndpoint(_ options: AuthorizeOptions, verifier: CodeVerifier) throws -> URL {
        let configuration = try self.apiClient.syncFetchOIDCConfiguration()
        var queryItems = [URLQueryItem]()
        if self.isThirdParty {
            queryItems.append(contentsOf: [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(
                    name: "scope",
                    value: "openid offline_access https://authgear.com/scopes/full-access"
                ),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "code_challenge", value: verifier.computeCodeChallenge()),
            ])

        } else {
            queryItems.append(contentsOf: [
                URLQueryItem(name: "response_type", value: "none"),
                URLQueryItem(
                    name: "scope",
                    value: "openid https://authgear.com/scopes/full-access"
                )
            ])
        }

        queryItems.append(URLQueryItem(name: "client_id", value: self.clientId))
        queryItems.append(URLQueryItem(name: "redirect_uri", value: options.redirectURI))

        if let state = options.state {

            queryItems.append(URLQueryItem(name: "state", value: state))
        }

        if let prompt = options.prompt {
            queryItems.append(URLQueryItem(name: "prompt", value: prompt))
        }

        if let loginHint = options.loginHint {
            queryItems.append(URLQueryItem(name: "login_hint", value: loginHint))
        }

        if let uiLocales = options.uiLocales {
            queryItems.append(URLQueryItem(
                name: "ui_locales",
                value: uiLocales.joined(separator: " ")
            ))
        }

        var urlComponents = URLComponents(
           url: configuration.authorizationEndpoint,
           resolvingAgainstBaseURL: false
        )!

        urlComponents.queryItems = queryItems

        return urlComponents.url!
    }

    private func authorize(_ options: AuthorizeOptions,
                          handler: @escaping AuthorizeCompletionHandler) {
        let verifier = CodeVerifier()
        do {
            let url = try self.authorizeEndpoint(options, verifier: verifier)
            DispatchQueue.main.async {
                self.authenticationSession = self.authenticationSessionProvider.makeAuthenticationSession(
                    url: url,
                    callbackURLSchema: options.urlScheme,
                    completionHandler: { [weak self] result in
                        switch result {
                        case .success(let url):
                            self?.finishAuthorization(url: url, verifier: verifier, handler: handler)
                        case .failure(let error):
                            switch error {
                            case .canceledLogin:
                                return handler(
                                    .failure(AuthgearError.canceledLogin)
                                )
                            case .sessionError(let error):
                                return handler(
                                    .failure(AuthgearError.unexpectedError(error))
                                )
                            }
                        }
                    }
                )
                self.authenticationSession?.start()
            }
        } catch {
            handler(.failure(error))
        }
    }

    private func finishAuthorization(url: URL,
                                     verifier: CodeVerifier,
                                     handler: @escaping AuthorizeCompletionHandler) {
        let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let params = urlComponents.queryParams
        let state = params["state"]

        if let errorParams = params["error"] {
            return handler(
                .failure(AuthgearError.oauthError(
                    error: errorParams,
                    description: params["error_description"]
                ))
            )
        }

        if !self.isThirdParty {
            self.apiClient.requestOIDCUserInfo(accessToken: nil) { result in
                handler(result.map { AuthorizeResponse(userInfo: $0, state: state)})
            }
        } else {
            guard let code = params["code"] else {
                return handler(
                    .failure(AuthgearError.oauthError(
                        error: "invalid_request",
                        description: "Missing parameter: code")
                    )
                )
            }
            let redirectURI = { () -> String in
                var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                urlComponents.fragment = nil
                urlComponents.query = nil

                return urlComponents.url!.absoluteString
            }()


            do {
                let tokenResponse = try self.apiClient.syncRequestOIDCToken(
                    grantType: GrantType.authorizationCode,
                    clientId: self.clientId,
                    redirectURI: redirectURI,
                    code: code,
                    codeVerifier: verifier.value,
                    refreshToken: nil,
                    jwt: nil
                )

                let userInfo = try self.apiClient.syncRequestOIDCUserInfo(accessToken: tokenResponse.accessToken)
                try self.persistTokenResponse(tokenResponse)

                handler(.success(AuthorizeResponse(userInfo: userInfo, state: state)))
            } catch {
                handler(.failure(error))
            }
        }
    }

    private func persistTokenResponse(
        _ tokenResponse: TokenResponse
    ) throws {
        self.accessToken = tokenResponse.accessToken
        self.refreshToken = tokenResponse.refreshToken
        self.expireAt = Date(timeIntervalSinceNow: TimeInterval(tokenResponse.expiresIn))

        if let refreshToekn = tokenResponse.refreshToken {
            try self.storage.setRefreshToken(namespace: self.name, token: refreshToekn)
        }
    }

    private func cleanupSession() throws {
        try self.storage.delRefreshToken(namespace: self.name)
        try self.storage.delAnonymousKeyId(namespace: self.name)
        self.accessToken = nil
        self.refreshToken = nil
        self.expireAt = nil

    }

    public func authorize(
        redirectURI: String,
        state: String? = nil,
        prompt: String? = nil,
        loginHint: String? = nil,
        uiLocales: [String]? = nil,
        handler: @escaping AuthorizeCompletionHandler
    ) {
        DispatchQueue.global(qos: .utility).async {
            self.authorize(
                AuthorizeOptions(
                    redirectURI: redirectURI,
                    state: state,
                    prompt: prompt,
                    loginHint: loginHint,
                    uiLocales: uiLocales
                ),
                handler: handler
            )
        }
    }

    public func authenticateAnonymously(
        handler: @escaping AuthorizeCompletionHandler
    ) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let token = try self.apiClient.syncRequestOAuthChallenge(purpose: "anonymous_request").token
                let keyId = try self.storage.getAnonymousKeyId(namespace: self.name) ?? UUID().uuidString
                let tag = "com.authgear.keys.anonymous.\(keyId)"

                let header: AnonymousJWTHeader
                if let key = try self.jwkStore.loadKey(keyId: keyId, tag: tag) {
                    header = AnonymousJWTHeader(jwk: key, new: false)
                } else {
                    let key = try self.jwkStore.generateKey(keyId: keyId, tag: tag)
                    header = AnonymousJWTHeader(jwk: key, new: true)
                }

                let payload = AnonymousJWYPayload(challenge: token, action: .auth)

                let jwt = AnonymousJWT(header: header, payload: payload)

                let privateKey = try self.jwkStore.loadPrivateKey(tag: tag)!

                let signedJWT = try jwt.sign(with: JWTSigner(privateKey: privateKey))

                let tokenResponse = try self.apiClient.syncRequestOIDCToken(
                    grantType: .anonymous,
                    clientId: self.clientId,
                    redirectURI: nil,
                    code: nil,
                    codeVerifier: nil,
                    refreshToken: nil,
                    jwt: signedJWT
                )

                let userInfo = try self.apiClient.syncRequestOIDCUserInfo(accessToken: tokenResponse.accessToken)

                try self.persistTokenResponse(tokenResponse)
                try self.storage.setAnonymousKeyId(namespace: self.name, kid: keyId)

                handler(.success(AuthorizeResponse(userInfo: userInfo, state: nil)))
            } catch {
                handler(.failure(error))
            }
        }
    }

    public func promoteAnonymousUser(
        redirectURI: String,
        state: String? = nil,
        uiLocales: [String]? = nil,
        handler: @escaping AuthorizeCompletionHandler
    ) {
        DispatchQueue.global(qos: .utility).async {
            do {
                guard let keyId = try self.storage.getAnonymousKeyId(namespace: self.name) else {
                    return handler(.failure(AuthgearError.anonymousUserNotFound))
                }

                let tag = "com.authgear.keys.anonymous.\(keyId)"
                let token = try self.apiClient.syncRequestOAuthChallenge(purpose: "anonymous_request").token

                let header: AnonymousJWTHeader
                if let key = try self.jwkStore.loadKey(keyId: keyId, tag: tag) {
                    header = AnonymousJWTHeader(jwk: key, new: false)
                } else {
                    let key = try self.jwkStore.generateKey(keyId: keyId, tag: tag)
                    header = AnonymousJWTHeader(jwk: key, new: true)
                }

                let payload = AnonymousJWYPayload(challenge: token, action: .promote)

                let jwt = AnonymousJWT(header: header, payload: payload)

                let privateKey = try self.jwkStore.loadPrivateKey(tag: tag)!

                let signedJWT = try jwt.sign(with: JWTSigner(privateKey: privateKey))

                let loginHint = "https://authgear.com/login_hint?type=anonymous&jwt=\(signedJWT.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"

                self.authorize(
                    redirectURI: redirectURI,
                    state: state,
                    prompt: "login",
                    loginHint: loginHint,
                    uiLocales: uiLocales
                ) { [weak self] result in
                    guard let this = self else { return }

                    switch result {
                    case .success(let response):
                        try? this.storage.delAnonymousKeyId(namespace: this.name)
                        handler(.success(response
                            ))
                    case .failure(let error):
                        handler(.failure(error))
                    }
                }
            } catch {
                handler(.failure(error))
            }
        }
    }

    public func logout(
        force: Bool = false,
        redirectURI: String? = nil,
        handler: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            do {
                if self.isThirdParty {
                    let token = try self.storage.getRefreshToken(namespace: self.name)
                    try self.apiClient.syncRequestOIDCRevocation(refreshToken: token ?? "")
                }
                try self.cleanupSession()
                handler(.success(()))
            } catch {
                handler(.failure(error))
            }
        }
    }
}

extension AuthContainer: AuthAPIClientDelegate {
    func getAccessToken() -> String? {
        return self.accessToken
    }

    func shouldRefreshAccessToken() -> Bool {
        if self.refreshToken == nil {
            return false
        }

        guard accessToken != nil,
            let expireAt = self.expireAt,
            expireAt.timeIntervalSinceNow.sign == .minus  else {
                return true
        }

        return false
    }

    func refreshAccessToken(handler: VoidCompletionHandler?) {
        DispatchQueue.global(qos: .utility).async {

            do {
                guard let refreshToken = try self.storage.getRefreshToken(namespace: self.name) else {
                    try self.cleanupSession()
                    handler?(.success(()))
                    return
                }

                let tokenResponse = try self.apiClient.syncRequestOIDCToken(
                    grantType: GrantType.refreshToken,
                    clientId: self.clientId,
                    redirectURI: nil,
                    code: nil,
                    codeVerifier: nil,
                    refreshToken: refreshToken,
                    jwt: nil
                )

                try self.persistTokenResponse(tokenResponse)
            } catch {
                if let error = error as? AuthAPIClientError,
                   case let .oidcError(oidcError) = error,
                   oidcError.error == "invalid_grant"  {
                    self.delegate?.onRefreshTokenExpired()
                    try? self.cleanupSession()
                    handler?(.success(()))
                    return
                }
                handler?(.failure(error))
            }
        }
    }
}