import Foundation

@MainActor
extension InstagramClient {
    func profileQuery(credentials: InstagramCredentials, identifier: String, posts: Bool = false, cursor: String? = nil, count: Int = 12) async throws -> Data {
        let lookup = identifier.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard lookup.range(of: #"^[A-Za-z0-9._]+$"#, options: .regularExpression) != nil else {
            throw SourceError.serviceError("Instagram profile is missing a valid username or account ID.")
        }
        let state = try await ensureBootstrappedState(credentials: credentials)
        let operation = posts ? "PolarisProfilePostsQuery" : "PolarisProfilePageContentQuery"
        let numericID = lookup.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil
        var profileID = numericID ? lookup : nil
        var username: String? = numericID ? nil : lookup
        if posts, numericID {
            username = try await userInfo(uid: lookup).user.username
        }
        if !knowsQuery(operation) || (!posts && profileID == nil) {
            let pageUsername: String = if let username { username }
            else { try instagramHomepageViewer(html: state.html, accountID: credentials.dsUserId).username }
            let html = try await webTextRequest(credentials: credentials, method: "GET", url: URL(string: Self.baseURL + "/\(pageUsername.urlPathEncoded)/")!, headers: basePageHeaders(credentials: credentials))
            if profileID == nil, !posts {
                profileID = instagramProfileRouteID(html: html)
            }
            learnQueries(from: html)
            for url in scriptURLs(html: html) {
                if knowsQuery(operation) { break }
                let source = try await webTextRequest(credentials: credentials, method: "GET", url: url, headers: ["User-Agent": Self.webUserAgent])
                learnQueries(from: source)
            }
        }
        guard let docID = docIds[operation], let providerNames = queryProviders[operation] else {
            throw SourceError.serviceError("Instagram's current page did not include its profile query.")
        }
        var variables = try instagramProvidedVariables(html: state.html, names: providerNames, providers: relayProviders)
        if posts {
            guard let username, !username.isEmpty else { throw SourceError.invalidResponse }
            variables["username"] = username
            variables["data"] = ["count": count, "include_reel_media_seen_timestamp": true, "include_relationship_info": true, "latest_besties_reel_media": true, "latest_reel_media": true]
            if let cursor, !cursor.isEmpty { variables["after"] = cursor }
        } else {
            guard let profileID else { throw SourceError.serviceError("This Instagram profile is unavailable.") }
            variables["id"] = profileID
            variables["enable_integrity_filters"] = true
        }
        // As the web client sends Relay queries: a GET of /graphql/query/ is answered `"spam":true` (observed 2026-11-21).
        let data = try await graphqlPost(
            credentials: credentials,
            docID: docID,
            variables: variables,
            friendlyName: operation,
            rootFieldName: posts ? "xdt_api__v1__feed__user_timeline_graphql_connection" : nil,
            endpoint: "/graphql/query",
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SourceError.invalidResponse }
        // Errors on single fields come with the data, as `field_exception` on a post's `location.profile_pic_url`
        // does (observed 2026-11-21); the web client shows the rest, so only a missing root fails the query.
        let root = posts ? "xdt_api__v1__feed__user_timeline_graphql_connection" : "user"
        if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty, ((json["data"] as? [String: Any])?[root] as? [String: Any]) == nil {
            let messages = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
            throw SourceError.serviceError("Instagram's \(operation) failed: \(messages.isEmpty ? "no message" : messages)")
        }
        if !posts {
            let response = try JSONDecoder().decode(InstagramProfileQueryResponse.self, from: data)
            guard let user = response.data.user, let pk = user.pk, String(pk) == profileID, user.username?.isEmpty == false else {
                throw SourceError.serviceError("Instagram answered with a different profile, or none.")
            }
        }
        return data
    }

    /// Whether the query's doc id, the providers it passes and each provider's definition are known.
    private func knowsQuery(_ operation: String) -> Bool {
        guard docIds[operation] != nil, let names = queryProviders[operation] else { return false }
        return names.allSatisfy { relayProviders[$0] != nil }
    }

    /// Doc ids, each query's providers and each provider's definition from a page or bundle, kept for later queries.
    private func learnQueries(from source: String) {
        docIds.merge(parseDocIds(source: source)) { _, new in new }
        relayProviders.merge(instagramRelayProviders(source: source)) { _, new in new }
        for operation in ["PolarisProfilePageContentQuery", "PolarisProfilePostsQuery"] {
            if let names = instagramQueryProviders(source: source, operation: operation) {
                queryProviders[operation] = names
            }
        }
    }
}

func instagramPageObjects(html: String) -> [Any] {
    guard let regex = try? NSRegularExpression(pattern: #"<script\b[^>]*\bdata-sjs[^>]*>(.*?)</script>"#, options: [.dotMatchesLineSeparators]) else { return [] }
    return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
        guard let range = Range(match.range(at: 1), in: html), let data = String(html[range]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

func instagramProfileRouteID(html: String) -> String? {
    func find(_ value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            if let info = dictionary["initialRouteInfo"] as? [String: Any],
               let route = info["route"] as? [String: Any], let root = route["rootView"] as? [String: Any],
               let props = root["props"] as? [String: Any], let id = props["id"] as? String,
               id.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
               let logging = props["page_logging"] as? [String: Any], let params = logging["params"] as? [String: Any], params["profile_id"] != nil { return id }
            return dictionary.values.lazy.compactMap(find).first
        }
        return (value as? [Any])?.lazy.compactMap(find).first
    }
    return instagramPageObjects(html: html).lazy.compactMap(find).first
}

/// A Relay provider the web client computes a query variable with (`__relay_internal__pv__<Name>relayprovider`): the
/// config table it reads, the id it reads, and whether it compares the value to `true` (`===!0`).
struct InstagramRelayProvider: Equatable {
    enum Table: String {
        case gkx, qex, justknobx

        /// The page's data for the table, and the field holding a value.
        var data: (key: String, field: String) {
            switch self {
            case .gkx: ("gkxData", "result")
            case .qex: ("qexData", "r")
            case .justknobx: ("justknobxData", "r")
            }
        }
    }

    let table: Table
    let id: String
    let isStrict: Bool
}

/// Every provider module in a bundle: `__d("<Name>.relayprovider",["gkx"],…r("gkx")("123")===!0…`.
func instagramRelayProviders(source: String) -> [String: InstagramRelayProvider] {
    let pattern = #"__d\("(\w+)\.relayprovider",\["(gkx|qex|justknobx)"\].{0,200}?r\("\2"\)(?:\._)?\("(\d+)"\)(===!0)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [:] }
    var providers: [String: InstagramRelayProvider] = [:]
    for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
        guard let name = Range(match.range(at: 1), in: source), let table = Range(match.range(at: 2), in: source),
              let id = Range(match.range(at: 3), in: source), let kind = InstagramRelayProvider.Table(rawValue: String(source[table]))
        else { continue }
        providers[String(source[name])] = InstagramRelayProvider(table: kind, id: String(source[id]), isStrict: match.range(at: 4).location != NSNotFound)
    }
    return providers
}

/// The providers a query's `.graphql` module passes, or nil when the bundle doesn't define the query.
func instagramQueryProviders(source: String, operation: String) -> [String]? {
    guard let start = source.range(of: "__d(\"\(operation).graphql\"") else { return nil }
    let rest = source[start.upperBound...]
    let module = rest.range(of: "__d(").map { rest[..<$0.lowerBound] } ?? rest
    guard let regex = try? NSRegularExpression(pattern: #"__relay_internal__pv__([A-Za-z0-9]+)relayprovider"#) else { return nil }
    let text = String(module)
    let names = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
        Range(match.range(at: 1), in: text).map { String(text[$0]) }
    }
    return Array(Set(names)).sorted()
}

/// The query's provided variables as the web client computes them, from the page's `gkxData`, `qexData` and
/// `justknobxData`. Instagram changes which providers a query takes and where each reads from (2026-11-21: Short
/// Drama moved from config 1697 and gate 12774 to JustKnobs 14), so both come from its bundles, not from here.
func instagramProvidedVariables(html: String, names: [String], providers: [String: InstagramRelayProvider]) throws -> [String: Any] {
    let objects = instagramPageObjects(html: html)
    var variables: [String: Any] = [:]
    for name in names {
        guard let provider = providers[name] else {
            throw SourceError.serviceError("Instagram profile configuration is missing. Reconnect and try again.")
        }
        let (key, field) = provider.table.data
        func find(_ value: Any) -> Any? {
            if let dictionary = value as? [String: Any] {
                if let data = dictionary[key] as? [String: Any], let entry = data[provider.id] as? [String: Any], let value = entry[field] {
                    return value
                }
                return dictionary.values.lazy.compactMap(find).first
            }
            return (value as? [Any])?.lazy.compactMap(find).first
        }
        guard let value = objects.lazy.compactMap(find).first else {
            throw SourceError.serviceError("Instagram profile configuration is missing. Reconnect and try again.")
        }
        let bool = value as? Bool
        variables["__relay_internal__pv__\(name)relayprovider"] = provider.isStrict ? bool == true : (bool ?? ((value as? NSNumber)?.boolValue ?? false))
    }
    return variables
}
