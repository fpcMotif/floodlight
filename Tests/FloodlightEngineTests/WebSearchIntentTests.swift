import XCTest
@testable import FloodlightEngine

final class WebSearchIntentTests: XCTestCase {
    func testEmptyQueryIsNeverPromoted() {
        XCTAssertFalse(WebSearchIntent.shouldPromote(query: "", localMatchCount: 0))
    }

    func testWeakLocalMatchCountsPromoteTheQuery() {
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "shortcut", localMatchCount: 0))
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "shortcut", localMatchCount: 1))
        XCTAssertTrue(
            WebSearchIntent.shouldPromote(
                query: "shortcut",
                localMatchCount: WebSearchIntent.weakMatchThreshold
            )
        )
    }

    func testHealthyLocalMatchCountsDoNotPromoteAPlainQuery() {
        XCTAssertFalse(
            WebSearchIntent.shouldPromote(
                query: "shortcut",
                localMatchCount: WebSearchIntent.weakMatchThreshold + 1
            )
        )
    }

    func testQuestionShapedQueriesArePromotedRegardlessOfLocalMatches() {
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "how do I reset my password", localMatchCount: 50))
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "what is the weather", localMatchCount: 50))
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "is docker free?", localMatchCount: 50))
    }

    func testURLShapedQueriesArePromotedRegardlessOfLocalMatches() {
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "github.com", localMatchCount: 50))
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "https://apple.com/mac", localMatchCount: 50))
    }

    func testPlainQueryWithHealthyMatchesIsNotPromoted() {
        XCTAssertFalse(WebSearchIntent.shouldPromote(query: "budget report", localMatchCount: 12))
    }

    func testLooksLikeQuestionRecognizesLeadingWordsAndTrailingQuestionMarks() {
        XCTAssertTrue(WebSearchIntent.looksLikeQuestion("how to install docker"))
        XCTAssertTrue(WebSearchIntent.looksLikeQuestion("Is this free?"))
        XCTAssertFalse(WebSearchIntent.looksLikeQuestion("budget report"))
        XCTAssertFalse(WebSearchIntent.looksLikeQuestion(""))
    }

    func testLooksLikeURLRejectsMultiWordQueriesAndBarePhrases() {
        XCTAssertTrue(WebSearchIntent.looksLikeURL("apple.com"))
        XCTAssertFalse(WebSearchIntent.looksLikeURL("apple pie recipe"))
        XCTAssertFalse(WebSearchIntent.looksLikeURL("budget"))
    }
}
