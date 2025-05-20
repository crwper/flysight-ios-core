//
//  DirectoryEntry.swift
//
//
//  Created by Michael Cooper on 2024-05-25.
//

import Foundation

public extension FlySightCore {
    struct DirectoryEntry: Identifiable {
        public let id: UUID
        public let size: UInt32
        public let date: Date
        public let attributes: String
        public let name: String
        public let isEmptyMarker: Bool

        public var isFolder: Bool {
            attributes.contains("d")
        }

        public var isHidden: Bool {
            attributes.contains("h")
        }

        // Helper to format the date
        public var formattedDate: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: date)
        }

        // Initializer will now correctly assign self.id once
        public init(id: UUID = UUID(), size: UInt32, date: Date, attributes: String, name: String, isEmptyMarker: Bool = false) {
            self.id = id
            self.size = size
            self.date = date
            self.attributes = attributes
            self.name = name
            self.isEmptyMarker = isEmptyMarker
        }
    }
}
