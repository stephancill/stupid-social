import Foundation
@testable import StupidSocialCore
import XCTest

/// `source_error` reports carry where decoding failed as key names only: no array positions or dictionary keys.
final class AppMetricsDecodingPathTests: XCTestCase {
    private struct Response: Decodable {
        let notifications: [Item]
        let users: [String: User]?
    }

    private struct Item: Decodable {
        let castTimestamp: String
    }

    private struct User: Decodable {
        let fid: UInt64
    }

    private func path(_ json: String) -> String? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            _ = try decoder.decode(Response.self, from: Data(json.utf8))
            XCTFail("decoded")
            return nil
        } catch {
            return AppMetrics.decodingPath(error)
        }
    }

    func testTypeMismatchInArray() {
        XCTAssertEqual(path(#"{"notifications":[{"cast_timestamp":"a"},{"cast_timestamp":5}]}"#), "notifications.[].castTimestamp")
    }

    func testMissingKeyIncludesKey() {
        XCTAssertEqual(path(#"{"notifications":[{}]}"#), "notifications.[].castTimestamp")
    }

    func testDictionaryKeysAreHidden() {
        XCTAssertEqual(path(#"{"notifications":[],"users":{"alice":{"fid":"x"}}}"#), "users.{}.fid")
        let numeric = path(#"{"notifications":[],"users":{"1689":{"fid":"x"}}}"#)
        XCTAssertFalse(numeric?.contains("1689") ?? true)
        XCTAssertEqual(numeric?.hasSuffix(".fid"), true)
    }

    func testOtherErrorsHaveNoPath() {
        XCTAssertNil(AppMetrics.decodingPath(URLError(.timedOut)))
        XCTAssertNil(path("[]"))
    }

    private enum Key: String, CodingKey {
        case someRatherLongFieldName, failingField
    }

    func testLongPathsKeepTheEnd() {
        let keys = Array(repeating: Key.someRatherLongFieldName, count: 5) + [Key.failingField]
        let error = DecodingError.typeMismatch(Int.self, .init(codingPath: keys, debugDescription: ""))
        let path = AppMetrics.decodingPath(error)
        XCTAssertEqual(path?.count, 64)
        XCTAssertEqual(path?.hasPrefix("…"), true)
        XCTAssertEqual(path?.hasSuffix(".failingField"), true)
    }
}
