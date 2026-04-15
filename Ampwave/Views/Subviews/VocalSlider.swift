//
//  VocalSlider.swift
//  Ampwave
//
//  Created by Ome Asraf on 4/14/26.
//

internal import SwiftUI

struct VocalSlider: View {
    @Binding var value: Float
    @State private var isDragging = false
    
    // Apple Music Sing uses a range, but typically it doesn't go to zero
    private let minVocal: Float = 0.05
    
    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                   
                      
                    
                    // Background track - Thick capsule with material
                    
                    Capsule()
                        .fill(.white.opacity(0.15))
                        .background(.ultraThinMaterial)
                    
                    // Active level - Bright white
                    Capsule()
                        .fill(.white)
                        .frame(height: geometry.size.height * CGFloat(value))
                        .shadow(color: .white.opacity(0.3), radius: 5)
                    Image(systemName: "waveform.path")
                        .frame(height: geometry.size.height)
                        .foregroundStyle(value > 0.5 ? .black : .white)
                }
                .clipShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            isDragging = true
                            let height = geometry.size.height
                            let rawValue = 1.0 - Float(gesture.location.y / height)
                            // Enforce minimum of 10%
                            value = min(max(rawValue, minVocal), 1.0)
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
            }
            .frame(width: 44, height: 200) // Slightly wider like iOS 17 sliders
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }
}

#Preview {
    ZStack {
        Color.pink.opacity(0.8).ignoresSafeArea()
        VocalSlider(value: .constant(0.6))
    }
}
