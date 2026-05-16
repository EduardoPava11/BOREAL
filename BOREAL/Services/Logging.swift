import Foundation
import os

enum Log {
    static let subsystem = "com.daniel.boreal"
    static let capture    = Logger(subsystem: subsystem, category: "capture")
    static let processing = Logger(subsystem: subsystem, category: "processing")
    static let burst      = Logger(subsystem: subsystem, category: "burst")
    static let ui         = Logger(subsystem: subsystem, category: "ui")
}
