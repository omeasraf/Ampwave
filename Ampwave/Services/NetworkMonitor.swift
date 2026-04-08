//
//  NetworkMonitor.swift
//  Ampwave
//

import Foundation
import Network
import Observation

@MainActor
@Observable
final class NetworkMonitor {
    
    static let shared = NetworkMonitor()
    
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "NetworkMonitorQueue")
    
    var status: NetworkStatus = .unknown
    
    var isOnline: Bool {
        if case .online = status { return true }
        return false
    }
    
    private init() {
        monitor = NWPathMonitor()
        
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            
            // Because this type is @MainActor,
            // hop back to main actor safely
            Task { @MainActor in
                self.updateStatus(from: path)
            }
        }
        
        monitor.start(queue: queue)
    }
    
    private func updateStatus(from path: NWPath) {
        guard path.status == .satisfied else {
            status = .offline
            return
        }
        
        let connectionType: ConnectionType
        
        if path.usesInterfaceType(.wifi) {
            connectionType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            connectionType = .cellular
        } else {
            connectionType = .ethernet
        }
        
        status = .online(connectionType: connectionType)
    }
}
