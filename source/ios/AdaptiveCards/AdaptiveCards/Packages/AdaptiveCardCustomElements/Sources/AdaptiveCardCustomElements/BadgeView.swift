//
//  BadgeView.swift
//  AdaptiveCardCustomElements
//
//  SwiftUI view for Badge custom element
//

import SwiftUI

/// SwiftUI view that displays a badge with text and optional icon
public struct BadgeView: View {
    let data: BadgeData
    
    public init(data: BadgeData) {
        self.data = data
    }
    
    public var body: some View {
        HStack(spacing: 4) {
            if let icon = data.icon {
                Image(systemName: icon)
                    .font(iconFont)
            }
            
            Text(data.text)
                .font(textFont)
                .fontWeight(.medium)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .foregroundColor(textColorValue)
        .background(backgroundColorValue)
        .cornerRadius(cornerRadius)
    }
    
    // MARK: - Computed Properties
    
    private var badgeSize: BadgeSize {
        switch data.size?.lowercased() {
        case "small":
            return .small
        case "large":
            return .large
        default:
            return .medium
        }
    }
    
    private var textFont: Font {
        switch badgeSize {
        case .small:
            return .caption2
        case .medium:
            return .caption
        case .large:
            return .subheadline
        }
    }
    
    private var iconFont: Font {
        switch badgeSize {
        case .small:
            return .caption2
        case .medium:
            return .caption
        case .large:
            return .body
        }
    }
    
    private var horizontalPadding: CGFloat {
        switch badgeSize {
        case .small:
            return 6
        case .medium:
            return 8
        case .large:
            return 12
        }
    }
    
    private var verticalPadding: CGFloat {
        switch badgeSize {
        case .small:
            return 2
        case .medium:
            return 4
        case .large:
            return 6
        }
    }
    
    private var cornerRadius: CGFloat {
        switch badgeSize {
        case .small:
            return 4
        case .medium:
            return 6
        case .large:
            return 8
        }
    }
    
    private var backgroundColorValue: Color {
        if let colorHex = data.color {
            return Color(hex: colorHex) ?? .blue
        }
        return .blue
    }
    
    private var textColorValue: Color {
        if let colorHex = data.textColor {
            return Color(hex: colorHex) ?? .white
        }
        return .white
    }
    
    private enum BadgeSize {
        case small
        case medium
        case large
    }
}

// MARK: - Color Extension

extension Color {
    /// Initialize Color from hex string
    /// - Parameter hex: Hex color string (e.g., "#FF5733" or "FF5733")
    /// - Returns: Color or nil if hex string is invalid
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        
        guard Scanner(string: hex).scanHexInt64(&int) else {
            return nil
        }
        
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Preview

struct BadgeView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            BadgeView(data: BadgeData(text: "New", color: "#FF5733", size: "small"))
            BadgeView(data: BadgeData(text: "Featured", color: "#3498DB", size: "medium"))
            BadgeView(data: BadgeData(text: "Premium", color: "#9B59B6", size: "large", icon: "star.fill"))
            BadgeView(data: BadgeData(text: "Beta", color: "#F39C12", size: "medium", icon: "exclamationmark.triangle.fill"))
        }
        .padding()
    }
}
