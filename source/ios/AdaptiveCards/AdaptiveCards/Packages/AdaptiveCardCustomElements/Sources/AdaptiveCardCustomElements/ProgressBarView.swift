//
//  ProgressBarView.swift
//  AdaptiveCardCustomElements
//
//  SwiftUI view for ProgressBar custom element
//

import SwiftUI

/// SwiftUI view that displays a horizontal progress bar
public struct ProgressBarView: View {
    let data: ProgressBarData
    
    public init(data: ProgressBarData) {
        self.data = data
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = data.label {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 8)
                    
                    // Progress fill
                    RoundedRectangle(cornerRadius: 4)
                        .fill(progressColor)
                        .frame(width: geometry.size.width * clampedProgress, height: 8)
                }
            }
            .frame(height: 8)
        }
    }
    
    // MARK: - Computed Properties
    
    private var clampedProgress: CGFloat {
        return CGFloat(max(0.0, min(1.0, data.progress)))
    }
    
    private var progressColor: Color {
        // Green for complete/high progress, blue for medium, yellow for low
        if clampedProgress >= 0.8 {
            return Color.green
        } else if clampedProgress >= 0.5 {
            return Color.blue
        } else {
            return Color.orange
        }
    }
}

#if DEBUG
struct ProgressBarView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            ProgressBarView(data: ProgressBarData(progress: 0.25, label: "25% Complete"))
                .frame(height: 30)
                .padding()
            
            ProgressBarView(data: ProgressBarData(progress: 0.5, label: "50% Complete"))
                .frame(height: 30)
                .padding()
            
            ProgressBarView(data: ProgressBarData(progress: 0.75, label: "75% Complete"))
                .frame(height: 30)
                .padding()
            
            ProgressBarView(data: ProgressBarData(progress: 1.0, label: "100% Complete"))
                .frame(height: 30)
                .padding()
            
            ProgressBarView(data: ProgressBarData(progress: 0.6, label: nil))
                .frame(height: 30)
                .padding()
        }
        .previewLayout(.sizeThatFits)
    }
}
#endif
