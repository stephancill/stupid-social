import Foundation
@testable import StupidSocialCore
import XCTest

/// `listening-activity/v1/feed` in the shape recorded on 2026-11-07, with made-up users and ids.
final class SpotifyListeningActivityParserTests: XCTestCase {
    func testParsesFollowAndUserEntities() throws {
        let json = #"""
        {"entities":[
          {"followEntity":{"uri":"spotify:user:example-one","activity":{"entityUri":"spotify:track:4uLU6hMCjMI75M1A2tKUQC","contextUri":"spotify:playlist:37i9dQZF1DXcBWIGoYBM5M","isPlaying":true,"timestamp":"2026-11-07T13:26:31.053Z"}}},
          {"userEntity":{"uri":"spotify:user:example-two","activity":{"entityUri":"spotify:track:7ouMYWpwJ422jRcDASZB7P","isPlaying":false,"timestamp":"2026-11-05T08:00:00Z"}}}
        ]}
        """#

        let friends = try SpotifyListeningActivityParser.parse(Data(json.utf8))

        XCTAssertEqual(friends.count, 2)
        XCTAssertEqual(friends[0].username, "example-one")
        XCTAssertEqual(friends[0].trackId, "4uLU6hMCjMI75M1A2tKUQC")
        XCTAssertEqual(friends[0].contextURI, "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")
        XCTAssertTrue(friends[0].isPlaying)
        XCTAssertEqual(friends[0].timestamp.timeIntervalSince1970, 1_794_057_991.053, accuracy: 0.001)
        XCTAssertEqual(friends[1].username, "example-two")
        XCTAssertNil(friends[1].contextURI)
        XCTAssertFalse(friends[1].isPlaying)
        XCTAssertEqual(friends[1].timestamp.timeIntervalSince1970, 1_793_865_600)
    }

    func testSkipsUnknownEntityKindsAndEpisodesHaveNoTrackId() throws {
        let json = #"""
        {"entities":[
          {"somethingNew":{"uri":"spotify:user:example-three"}},
          {"followEntity":{"uri":"spotify:user:example-four","activity":{"entityUri":"spotify:episode:0Q86acNRm6V9GYx55SXKwf","isPlaying":false,"timestamp":"2026-11-07T10:00:00.000Z"}}}
        ]}
        """#

        let friends = try SpotifyListeningActivityParser.parse(Data(json.utf8))

        XCTAssertEqual(friends.map(\.username), ["example-four"])
        XCTAssertNil(friends[0].trackId)
    }

    func testEmptyFeed() throws {
        XCTAssertEqual(try SpotifyListeningActivityParser.parse(Data(#"{"entities":[]}"#.utf8)), [])
        XCTAssertEqual(try SpotifyListeningActivityParser.parse(Data("{}".utf8)), [])
    }

    func testUnreadableTimestampThrows() {
        let json = #"{"entities":[{"followEntity":{"uri":"spotify:user:x","activity":{"entityUri":"spotify:track:4uLU6hMCjMI75M1A2tKUQC","timestamp":"yesterday"}}}]}"#
        XCTAssertThrowsError(try SpotifyListeningActivityParser.parse(Data(json.utf8)))
    }
}
