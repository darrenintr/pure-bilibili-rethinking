import SwiftUI

#Preview("Feed – light") {
    ScrollView {
        DSFeedGrid {
            ForEach(0..<6, id: \.self) { i in
                DSVideoCard(
                    title: "示例影片標題 \(i)：這是一個很長的標題用來測試兩行截斷效果",
                    author: "UP 主",
                    viewsText: "\(DSFormat.count(123_456 * (i + 1)))播放",
                    durationText: DSFormat.duration(seconds: 215 + i * 400)
                ) {
                    LinearGradient(colors: [DSColor.accent, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
    }
    .background(DSColor.background)
}

#Preview("Feed – dark, skeleton") {
    ScrollView {
        DSFeedGrid {
            ForEach(0..<4, id: \.self) { _ in DSVideoCardSkeleton() }
        }
    }
    .background(DSColor.background)
    .preferredColorScheme(.dark)
}

#Preview("Controls – AX5") {
    VStack(spacing: DSSpacing.l) {
        HStack {
            DSChip("推薦", isSelected: true) {}
            DSChip("熱門", isSelected: false) {}
        }
        Button("登入") {}.buttonStyle(.dsPrimary)
        Text("Mini player").padding().dsGlassBar()
    }
    .padding()
    .background(DSColor.background)
    .dynamicTypeSize(.accessibility5)
}
