import Foundation

/// The canonical "Hello AdaptiveCards" sample from
/// <https://adaptivecards.io/samples/> — copied verbatim, not
/// paraphrased. This is the payload the symbol-check demo writes
/// through `SwiftKaBridge.AdaptiveCardStore.storeCard(...)` and reads
/// back with `loadCard(...)`.
enum SampleCard {
    static let json = #"""
{
  "type": "AdaptiveCard",
  "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
  "version": "1.5",
  "body": [
    {
      "type": "TextBlock",
      "text": "Hello, AdaptiveCards!",
      "size": "Large",
      "weight": "Bolder",
      "wrap": true
    },
    {
      "type": "TextBlock",
      "text": "This card is stored end-to-end through the vendored swiftka kit.",
      "wrap": true
    }
  ]
}
"""#

    static var jsonBytes: Data { Data(json.utf8) }
}
