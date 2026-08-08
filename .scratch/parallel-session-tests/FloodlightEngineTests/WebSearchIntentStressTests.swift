import Foundation
import XCTest
@testable import FloodlightEngine

/// Harsh, critical stress tests for `WebSearchIntent` — adversarial inputs
/// and boundary conditions for the web-search promotion logic.
final class WebSearchIntentStressTests: XCTestCase {

    // MARK: - Empty and whitespace

    func testEmptyAndWhitespaceQueriesAreNeverPromoted() {
        XCTAssertFalse(WebSearchIntent.shouldPromote(query: "", localMatchCount: 0))
        XCTAssertFalse(WebSearchIntent.shouldPromote(query: " ", localMatchCount: 0))
        XCTAssertFalse(WebSearchIntent.shouldPromote(query: "   ", localMatchCount: 0))
        XCTAssertFalse(WebSearchIntent.shouldPromote(query: "\t", localMatchCount: 0))
        XCTAssertFalse(WebSearchIntent.shouldPromote(query: "\n", localMatchCount: 0))
    }

    func testWhitespaceOnlyQuestionMarkIsPromoted() {
        // A bare "?" trimmed is empty, but with leading space it still ends with "?"
        XCTAssertTrue(WebSearchIntent.looksLikeQuestion("?"))
        XCTAssertTrue(WebSearchIntent.looksLikeQuestion(" ?"))
        XCTAssertTrue(WebSearchIntent.looksLikeQuestion("what?"))
    }

    // MARK: - Question word boundary

    func testAllQuestionWordsTriggerPromotion() {
        let words = ["how", "what", "why", "who", "when", "where",
                     "is", "are", "can", "does", "do", "should", "will", "which"]
        for word in words {
            XCTAssertTrue(WebSearchIntent.looksLikeQuestion("\(word) something"),
                "'\(word)' should be recognized as a question word")
            XCTAssertTrue(WebSearchIntent.looksLikeQuestion("\(word.capitalized) something"),
                "'\(word.capitalized)' should be recognized case-insensitively")
        }
    }

    func testNonQuestionWordsDoNotTrigger() {
        let words = ["the", "a", "an", "budget", "report", "safari", "calendar"]
        for word in words {
            XCTAssertFalse(WebSearchIntent.looksLikeQuestion("\(word) something"),
                "'\(word)' should not be recognized as a question word")
        }
    }

    // MARK: - Question mark suffix

    func testTrailingQuestionMarkAlwaysTriggers() {
        for query in ["budget report?", "safari?", "a?", "x?"] {
            XCTAssertTrue(WebSearchIntent.looksLikeQuestion(query),
                "'\(query)' should be recognized as a question")
        }
    }

    func testQuestionMarkWithoutQuestionWord() {
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "budget report?", localMatchCount: 50))
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "safari?", localMatchCount: 50))
    }

    // MARK: - URL detection

    func testURLShapedQueriesArePromoted() {
        let urls = [
            "github.com", "apple.com", "google.com",
            "https://apple.com", "http://example.com",
            "stackoverflow.com/questions/123",
            "developer.apple.com/documentation",
            "en.wikipedia.org",
        ]
        for url in urls {
            XCTAssertTrue(WebSearchIntent.looksLikeURL(url),
                "'\(url)' should be recognized as a URL")
            XCTAssertTrue(WebSearchIntent.shouldPromote(query: url, localMatchCount: 50),
                "'\(url)' should be promoted")
        }
    }

    func testNonURLsAreNotDetectedAsURLs() {
        let nonURLs = [
            "budget", "safari", "hello world",
            "a b c", "just words here",
            "not a url at all",
        ]
        for query in nonURLs {
            XCTAssertFalse(WebSearchIntent.looksLikeURL(query),
                "'\(query)' should not be recognized as a URL")
        }
    }

    func testMultiWordQueriesAreNotURLs() {
        XCTAssertFalse(WebSearchIntent.looksLikeURL("github.com repository"))
        XCTAssertFalse(WebSearchIntent.looksLikeURL("visit apple.com today"))
    }

    // MARK: - Weak match threshold boundary

    func testWeakMatchThresholdBoundary() {
        let threshold = WebSearchIntent.weakMatchThreshold
        XCTAssertTrue(WebSearchIntent.shouldPromote(
            query: "plain", localMatchCount: threshold
        ), "at threshold should promote")
        XCTAssertFalse(WebSearchIntent.shouldPromote(
            query: "plain", localMatchCount: threshold + 1
        ), "above threshold should not promote")
    }

    func testZeroLocalMatchesAlwaysPromotes() {
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "anything", localMatchCount: 0))
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "a", localMatchCount: 0))
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "zzzzz", localMatchCount: 0))
    }

    // MARK: - Combined triggers

    func testQuestionWithWeakMatchesIsPromoted() {
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "how to code", localMatchCount: 0))
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "how to code", localMatchCount: 1))
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "how to code", localMatchCount: 2))
    }

    func testQuestionWithHealthyMatchesIsStillPromoted() {
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "how to code", localMatchCount: 100))
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "what is swift", localMatchCount: 100))
    }

    func testURLWithHealthyMatchesIsStillPromoted() {
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "github.com", localMatchCount: 100))
    }

    // MARK: - Edge cases

    func testSingleCharacterQuery() {
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: "a", localMatchCount: 0))
        XCTAssertFalse(WebSearchIntent.shouldPromote(query: "a", localMatchCount: 3))
    }

    func testVeryLongQuery() {
        let long = String(repeating: "word ", count: 100) + "?"
        XCTAssertTrue(WebSearchIntent.looksLikeQuestion(long))
        XCTAssertTrue(WebSearchIntent.shouldPromote(query: long, localMatchCount: 50))
    }

    func testQueryWithOnlyPunctuation() {
        XCTAssertFalse(WebSearchIntent.looksLikeQuestion("!!!"))
        XCTAssertFalse(WebSearchIntent.looksLikeQuestion("..."))
        XCTAssertTrue(WebSearchIntent.looksLikeQuestion("?"))
    }

    // MARK: - looksLikeQuestion edge cases

    func testLooksLikeQuestionEmptyAfterTrim() {
        XCTAssertFalse(WebSearchIntent.looksLikeQuestion(""))
        XCTAssertFalse(WebSearchIntent.looksLikeQuestion(" "))
    }

    func testLooksLikeQuestionSingleWord() {
        XCTAssertFalse(WebSearchIntent.looksLikeQuestion("budget"))
        XCTAssertFalse(WebSearchIntent.looksLikeQuestion("safari"))
        XCTAssertTrue(WebSearchIntent.looksLikeQuestion("how"))
        XCTAssertTrue(WebSearchIntent.looksLikeQuestion("why"))
    }

    // MARK: - looksLikeURL edge cases

    func testLooksLikeURLEmptyAfterTrim() {
        XCTAssertFalse(WebSearchIntent.looksLikeURL(""))
        XCTAssertFalse(WebSearchIntent.looksLikeURL(" "))
    }

    func testLooksLikeURLWithSpaces() {
        XCTAssertFalse(WebSearchIntent.looksLikeURL("apple.com "))
        XCTAssertFalse(WebSearchIntent.looksLikeURL(" apple.com"))
    }
}
