//
//  ViewExtensions.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/16/26.
//

internal import SwiftUI

extension View {
    func subtitle(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            self
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
