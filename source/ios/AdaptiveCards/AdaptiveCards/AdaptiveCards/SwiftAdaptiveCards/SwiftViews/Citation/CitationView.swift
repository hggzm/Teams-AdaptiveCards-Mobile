//
//  CitationView.swift
//  AdaptiveCards
//
//  Created on 11/09/25.
//  Copyright © 2025 Microsoft. All rights reserved.
//

import SwiftUI

/// SwiftUI view for rendering citation elements
/// Displays a compact citation badge that expands to show full details
@available(iOS 15.0, *)
struct CitationView: View {
    
    let data: SwiftCitationData
    var onHeightChange: (() -> Void)? = nil
    
    @State private var showDetails = false
    @State private var isHovered = false
    
    var body: some View {
        Button(action: {
            showDetails = true
        }) {
            HStack(spacing: 4) {
                // Citation badge
                Text(data.displayText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue.opacity(isHovered ? 0.15 : 0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )
            }
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .sheet(isPresented: $showDetails) {
            CitationDetailView(data: data)
        }
        .accessibilityLabel("Citation \(data.displayText)")
        .accessibilityHint("Double tap to view citation details")
    }
}

/// Detail view showing full citation information
@available(iOS 15.0, *)
struct CitationDetailView: View {
    
    let data: SwiftCitationData
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Citation number badge
                    HStack {
                        Text(data.displayText)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.blue)
                            .padding(12)
                            .background(
                                Circle()
                                    .fill(Color.blue.opacity(0.1))
                            )
                        
                        Spacer()
                    }
                    .padding(.bottom, 8)
                    
                    // Title
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Title")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        
                        Text(data.citation.title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    
                    Divider()
                    
                    // Authors (if available)
                    if let authors = data.citation.authors, !authors.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Authors")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                            
                            ForEach(authors, id: \.self) { author in
                                HStack(spacing: 8) {
                                    Image(systemName: "person.circle.fill")
                                        .foregroundColor(.gray)
                                        .font(.system(size: 14))
                                    
                                    Text(author)
                                        .font(.body)
                                }
                            }
                        }
                        
                        Divider()
                    }
                    
                    // Publication info
                    HStack(spacing: 16) {
                        if let year = data.citation.year {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Year")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textCase(.uppercase)
                                
                                Text("\(year)")
                                    .font(.body)
                                    .fontWeight(.medium)
                            }
                        }
                        
                        if let publisher = data.citation.publisher {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Publisher")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textCase(.uppercase)
                                
                                Text(publisher)
                                    .font(.body)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                    
                    if data.citation.year != nil || data.citation.publisher != nil {
                        Divider()
                    }
                    
                    // Snippet (if available)
                    if let snippet = data.citation.snippet {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Excerpt")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                            
                            Text(snippet)
                                .font(.body)
                                .foregroundColor(.secondary)
                                .italic()
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.gray.opacity(0.1))
                                )
                        }
                        
                        Divider()
                    }
                    
                    // URL link (if available)
                    if let url = data.citation.url {
                        Link(destination: url) {
                            HStack {
                                Image(systemName: "link.circle.fill")
                                    .font(.system(size: 20))
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("View Source")
                                        .font(.body)
                                        .fontWeight(.medium)
                                    
                                    Text(url.host ?? url.absoluteString)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 14))
                            }
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.blue.opacity(0.1))
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Citation Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Compact Inline Citation View (Alternative)

/// Minimal inline version that can be embedded in text flows
@available(iOS 15.0, *)
struct CompactCitationView: View {
    
    let data: SwiftCitationData
    @State private var showPopover = false
    
    var body: some View {
        Button(action: {
            showPopover = true
        }) {
            Text(data.displayText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.blue)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .popover(isPresented: $showPopover) {
            CitationPopoverView(data: data)
                .frame(width: 300)
        }
    }
}

/// Small popover preview of citation
@available(iOS 15.0, *)
struct CitationPopoverView: View {
    
    let data: SwiftCitationData
    @State private var showFullDetails = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text(data.displayText)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.blue)
                
                Spacer()
                
                Button(action: {
                    showFullDetails = true
                }) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14))
                }
            }
            
            // Title
            Text(data.citation.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(3)
            
            // Authors
            if let authors = data.citation.authors?.prefix(2) {
                Text(authors.joined(separator: ", "))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            // Snippet preview
            if let snippet = data.citation.snippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .padding(.top, 4)
            }
            
            // Link
            if data.citation.url != nil {
                Button(action: {
                    showFullDetails = true
                }) {
                    HStack {
                        Image(systemName: "link")
                            .font(.system(size: 12))
                        Text("View Full Citation")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(16)
        .sheet(isPresented: $showFullDetails) {
            CitationDetailView(data: data)
        }
    }
}

// MARK: - Previews

@available(iOS 15.0, *)
struct CitationView_Previews: PreviewProvider {
    static var previews: some View {
        let sampleCitation = SwiftCitationData(
            referenceId: 1,
            displayText: "[1]",
            citation: CitationInfo(
                title: "Machine Learning in Production: A Comprehensive Guide",
                url: URL(string: "https://arxiv.org/example"),
                snippet: "Machine learning systems require careful consideration of production constraints, including latency, throughput, and resource utilization...",
                authors: ["Dr. Jane Smith", "Prof. John Doe", "Dr. Alice Johnson"],
                year: 2024,
                publisher: "ACM Press"
            )
        )
        
        VStack(spacing: 20) {
            CitationView(data: sampleCitation)
            
            CompactCitationView(data: sampleCitation)
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
