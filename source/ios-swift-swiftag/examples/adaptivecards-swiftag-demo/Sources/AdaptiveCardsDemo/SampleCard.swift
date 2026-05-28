import Foundation

/// Canonical "Hello world" AdaptiveCard JSON, copied verbatim from
/// the Schema Explorer example at
/// <https://adaptivecards.io/explorer/AdaptiveCard.html>. Kept as
/// a raw string so the demo asserts byte-equality on round-trip.
enum SampleCard {
    static let json: String = """
{
    "type": "AdaptiveCard",
    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
    "version": "1.5",
    "body": [
        {
            "type": "TextBlock",
            "text": "Hello AdaptiveCards"
        }
    ]
}
"""
}
