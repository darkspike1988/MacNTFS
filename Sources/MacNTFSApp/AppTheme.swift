import SwiftUI

public enum AppTheme {
    public static let primaryRadius: CGFloat = 12
    public static let innerRadius: CGFloat = 8

    public static let accentColor = Color.accentColor
    public static let ntfsBlue = Color(red: 0.08, green: 0.48, blue: 0.98)
    public static let warningOrange = Color(red: 1.0, green: 0.58, blue: 0.0)
    public static let successGreen = Color(red: 0.2, green: 0.78, blue: 0.35)
}

extension View {
    public func appleCardStyle() -> some View {
        self
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.primaryRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.primaryRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}
