//
//  NetworkStatus.swift
//  Ampwave
//

import Foundation

enum NetworkStatus: Equatable {
    case unknown
    case offline
    case online(connectionType: ConnectionType)
}
