//
//  LibrarySortOrder.swift
//  Ampwave
//

import Foundation

enum LibrarySortOrder: String, Codable, CaseIterable {
    case titleAscending = "Title (A-Z)"
    case titleDescending = "Title (Z-A)"
    case artistAscending = "Artist (A-Z)"
    case artistDescending = "Artist (Z-A)"
    case dateAddedDescending = "Last Added"
    case dateAddedAscending = "Oldest Added"
    case yearDescending = "Year (Newest)"
    case yearAscending = "Year (Oldest)"
    
    var icon: String {
        switch self {
        case .titleAscending, .artistAscending, .yearAscending, .dateAddedAscending:
            return "arrow.up"
        case .titleDescending, .artistDescending, .yearDescending, .dateAddedDescending:
            return "arrow.down"
        }
    }
}
