import SwiftUI

public extension View {
    /// Floating-bar surface: Liquid Glass on iOS 26+, ultra-thin material
    /// before that. Use for the mini-player, tab accessory and player controls.
    @ViewBuilder
    func dsGlassBar(cornerRadius: CGFloat = DSRadius.sheet) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: RoundedRectangle.ds(cornerRadius))
        } else {
            self.dsMaterialBar(cornerRadius: cornerRadius)
        }
        #else
        self.dsMaterialBar(cornerRadius: cornerRadius)
        #endif
    }

    fileprivate func dsMaterialBar(cornerRadius: CGFloat) -> some View {
        self.background(.ultraThinMaterial, in: RoundedRectangle.ds(cornerRadius))
    }
}
