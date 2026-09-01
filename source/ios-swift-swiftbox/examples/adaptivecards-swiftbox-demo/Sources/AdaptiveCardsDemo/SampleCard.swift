// examples/adaptivecards-swiftbox-demo/Sources/AdaptiveCardsDemo/SampleCard.swift
//
// The canonical "Hello World" Adaptive Card, copied verbatim from
// https://adaptivecards.io/samples/ — the minimal Adaptive Card v1.4 payload
// any host renderer must accept. Used as the round-trip fixture.

let helloWorldCardJSON = """
{
    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
    "type": "AdaptiveCard",
    "version": "1.4",
    "body": [
        {
            "type": "TextBlock",
            "size": "Medium",
            "weight": "Bolder",
            "text": "Hello, Adaptive Cards"
        },
        {
            "type": "TextBlock",
            "text": "This card was round-tripped through a vendored swiftbox sandbox.",
            "wrap": true
        }
    ]
}
"""
