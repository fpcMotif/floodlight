import Foundation
import os

package enum FloodlightPerformance {
    static let log = OSLog(
        subsystem: "com.floodlight.app",
        category: .pointsOfInterest
    )

    package static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    package static func end(_ name: StaticString, id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }

    static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }
}
