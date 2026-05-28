// SampleCard — canonical AdaptiveCard "Hello World" payload.
//
// Taken from the AdaptiveCards.io Samples gallery (the simplest
// "Hello World" card variant). Embedded verbatim as a string so the
// demo does not need to read from disk before the swiftharness
// store has been exercised.
//
// https://adaptivecards.io/samples/

import Foundation

enum SampleCard {
    /// Canonical "Hello World" AdaptiveCard JSON payload, verbatim.
    static let helloWorldJSON: String = """
    {
        "type": "AdaptiveCard",
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "version": "1.5",
        "body": [
            {
                "type": "TextBlock",
                "text": "Hello World!",
                "size": "Large",
                "weight": "Bolder"
            }
        ]
    }
    """
}
