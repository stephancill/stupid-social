import Foundation

func instagramHomepageViewer(html: String, accountID: String) throws -> InstagramDirectViewer {
    let objects = instagramPageObjects(html: html)
    func loggedOut(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary["is_logged_out_user"] as? Bool == true || dictionary["is_logged_out_user_ssr"] as? Bool == true { return true }
            return dictionary.values.contains(where: loggedOut)
        }
        return (value as? [Any])?.contains(where: loggedOut) ?? false
    }
    guard !objects.contains(where: loggedOut) else { throw SourceError.notConfigured }
    func findViewer(_ value: Any) -> [String: Any]? {
        if let array = value as? [Any] {
            if array.first as? String == "PolarisViewer", array.count > 2 {
                return (array[2] as? [String: Any])?["data"] as? [String: Any]
            }
            return array.lazy.compactMap(findViewer).first
        }
        return (value as? [String: Any])?.values.lazy.compactMap(findViewer).first
    }
    guard let raw = objects.lazy.compactMap(findViewer).first else { throw SourceError.invalidResponse }
    let data = try JSONSerialization.data(withJSONObject: raw)
    let viewer = try JSONDecoder().decode(InstagramDirectViewer.self, from: data)
    guard let id = UInt64(viewer.pk), id > 0,
          viewer.username.range(of: #"^[A-Za-z0-9._]+$"#, options: .regularExpression) != nil else { throw SourceError.invalidResponse }
    guard viewer.pk == accountID else { throw SourceError.notConfigured }
    return viewer
}

func instagramHomepageTray(html: String, accountID: String) throws -> InstagramReelsTrayResponse {
    _ = try instagramHomepageViewer(html: html, accountID: accountID)
    func findTray(_ value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if let tray = dictionary["xdt_api__v1__feed__reels_tray"] as? [String: Any] { return tray }
            return dictionary.values.lazy.compactMap(findTray).first
        }
        return (value as? [Any])?.lazy.compactMap(findTray).first
    }
    guard let raw = instagramPageObjects(html: html).lazy.compactMap(findTray).first else { throw SourceError.invalidResponse }
    let data = try JSONSerialization.data(withJSONObject: raw)
    let tray = try JSONDecoder().decode(InstagramReelsTrayResponse.self, from: data)
    guard tray.tray.allSatisfy({ item in
        UInt64(item.id).map { $0 > 0 } == true && item.user.pk > 0 &&
            item.user.username?.range(of: #"^[A-Za-z0-9._]+$"#, options: .regularExpression) != nil
    }) else { throw SourceError.invalidResponse }
    return tray
}
