// SampleCard.swift
// Canonical "Hello World" Adaptive Card payload as published on
// https://adaptivecards.io/samples/ . Embedded verbatim so the runtime
// symbol-check exercises a real AdaptiveCard JSON shape, not a
// synthesized one.

import Foundation

enum SampleCard {
    /// The minimal "Hello World" Adaptive Card from adaptivecards.io,
    /// schema 1.5. Used as the artifact payload in the round-trip and as
    /// the byte-equality oracle.
    static let helloWorldJSON: String = """
    {
        "type": "AdaptiveCard",
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "version": "1.5",
        "body": [
            {
                "type": "TextBlock",
                "text": "Hello, World!"
            }
        ]
    }
    """
}
