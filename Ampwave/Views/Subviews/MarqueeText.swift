internal import SwiftUI

struct MarqueeText: View {
  let text: String
  let font: Font
  let color: Color
  
  @State private var offset: CGFloat = 0
  @State private var textWidth: CGFloat = 0
  @State private var containerWidth: CGFloat = 0
  @State private var isAnimating = false
  
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Text(text)
          .font(font)
          .foregroundStyle(color)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
          .background(
            GeometryReader { textGeometry in
              Color.clear
                .onAppear {
                  textWidth = textGeometry.size.width
                  containerWidth = geometry.size.width
                  checkAndStartAnimation()
                }
            }
          )
          .offset(x: offset)
      }
      .onAppear {
        containerWidth = geometry.size.width
      }
      .onChange(of: text) { _, _ in
        resetAnimation()
      }
      .onChange(of: textWidth) { _, _ in
        checkAndStartAnimation()
      }
    }
    .frame(height: 38)
    .clipped()
    .mask {
      HStack(spacing: 0) {
        Rectangle()
          .fill(LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing))
          .frame(width: offset < -5 ? 15 : 0)
        
        Rectangle()
          .fill(.black)
        
        Rectangle()
          .fill(LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing))
          .frame(width: textWidth > containerWidth && offset > -textWidth + containerWidth + 5 ? 15 : 0)
      }
    }
  }
  
  private func resetAnimation() {
    isAnimating = false
    withAnimation(.none) {
      offset = 0
    }
    // Small delay to allow layout to settle before re-calculating
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      checkAndStartAnimation()
    }
  }

  private func checkAndStartAnimation() {
    guard textWidth > containerWidth else { 
      offset = 0
      return 
    }
    
    guard !isAnimating else { return }
    isAnimating = true
    
    let animationDuration = Double(textWidth) / 30.0
    
    func runAnimation() {
      guard isAnimating else { return }
      
      offset = 0
      withAnimation(.linear(duration: animationDuration).delay(2.0)) {
        offset = -textWidth + containerWidth - 20
      }
      
      DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 4.0) {
        guard isAnimating else { return }
        withAnimation(.easeInOut(duration: 1.0)) {
          offset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
          runAnimation()
        }
      }
    }
    
    runAnimation()
  }
}
