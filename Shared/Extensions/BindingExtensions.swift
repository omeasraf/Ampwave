//
//  BindingExtensions.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/16/26.
//

internal import SwiftUI

extension Binding where Value == Bool? {
    func withDefault(_ value: Bool) -> Binding<Bool> {
        Binding<Bool>(
            get: { self.wrappedValue ?? value },
            set: { self.wrappedValue = $0 }
        )
    }
}
