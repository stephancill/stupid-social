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
        if docIds[operation] == nil || (!posts && profileID == nil) {
            let pageUsername: String = if let username { username }
            else { try await directInboxViewer(credentials: credentials).username }
            let html = try await webTextRequest(credentials: credentials, method: "GET", url: URL(string: Self.baseURL + "/\(pageUsername.urlPathEncoded)/")!, headers: basePageHeaders(credentials: credentials))
            if profileID == nil, !posts {
                profileID = instagramProfileRouteID(html: html)
            }
            docIds.merge(parseDocIds(source: html)) { _, new in new }
            for url in scriptURLs(html: html) {
                if docIds[operation] != nil { break }
                let source = try await webTextRequest(credentials: credentials, method: "GET", url: url, headers: ["User-Agent": Self.webUserAgent])
                docIds.merge(parseDocIds(source: source)) { _, new in new }
            }
        }
        guard let docID = docIds[operation] else {
            throw SourceError.serviceError("Instagram's current page did not include its profile query.")
        }
        var variables: [String: Any] = try instagramProfileVariables(html: state.html, posts: posts)
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
        let data = try await graphqlGet(credentials: credentials, docID: docID, variables: variables)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["errors"] as? [Any] ?? []).isEmpty else { throw SourceError.invalidResponse }
        if !posts {
            let response = try JSONDecoder().decode(InstagramProfileQueryResponse.self, from: data)
            guard let user = response.data.user, let pk = user.pk, String(pk) == profileID,
                  user.username?.isEmpty == false else { throw SourceError.invalidResponse }
        }
        return data
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

func instagramProfileVariables(html: String, posts: Bool) throws -> [String: Any] {
    let objects = instagramPageObjects(html: html)
    func config(_ identifier: String, field: String) throws -> Any {
        func find(_ value: Any) -> Any? {
            if let dictionary = value as? [String: Any] {
                if let entry = dictionary[identifier] as? [String: Any], let result = entry[field] { return result }
                return dictionary.values.lazy.compactMap(find).first
            }
            return (value as? [Any])?.lazy.compactMap(find).first
        }
        guard let value = objects.lazy.compactMap(find).first else {
            throw SourceError.serviceError("Instagram profile configuration is missing. Reconnect and try again.")
        }
        return value
    }
    func gate(_ identifier: String) throws -> Bool {
        guard let value = try config(identifier, field: "result") as? Bool else { throw SourceError.invalidResponse }
        return value
    }
    let shortDrama = try config("1697", field: "r") as? Bool == true
        ? config("3668", field: "r") as? Bool == true : gate("12774")
    var providers = ["PolarisShortDramaEnabled": shortDrama]
    if posts {
        providers["PolarisMultiCaptionCarouselEnabled"] = try config("2404", field: "r") as? Bool == true
        providers["PolarisReelsRecoDebugOverlayEnabled"] = try gate("684")
    } else {
        for (name, id) in ["PolarisCASB976ProfileEnabled": "17028", "PolarisCannesGuardianExperienceEnabled": "6793", "PolarisWebSchoolsEnabled": "17363", "PolarisRepostsConsumptionEnabled": "9448"] {
            providers[name] = try gate(id)
        }
    }
    return Dictionary(uniqueKeysWithValues: providers.map { ("__relay_internal__pv__\($0.key)relayprovider", $0.value as Any) })
}
