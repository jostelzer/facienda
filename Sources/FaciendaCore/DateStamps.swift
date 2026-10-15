import Foundation

extension Date {
    /// An ISO 8601 time safe for file names, for backups that sort by when they were made.
    var fileStamp: String { ISO8601DateFormatter().string(from: self).replacingOccurrences(of: ":", with: "-") }
}
