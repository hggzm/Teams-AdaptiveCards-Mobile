//
//  SwiftAdaptiveCardsWrapper.m
//  AdaptiveCards
//
//  Created by Hugo Gonzalez on 11/25/25.
//  Copyright © 2025 Microsoft. All rights reserved.
//

#import "SwiftAdaptiveCardsWrapper.h"

// Import Swift Package module (works in .m files)
@import SwiftAdaptiveCards;

@implementation SwiftAdaptiveCardsWrapper

+ (NSArray * _Nullable)getWarningsFromSwiftResult:(SwiftAdaptiveCardParseResult *)result {
    return [result warnings];
}

+ (BOOL)isSwiftParserEnabled {
    return [SwiftAdaptiveCardParser isSwiftParserEnabled];
}

+ (void)setSwiftParserEnabled:(BOOL)enabled {
    [SwiftAdaptiveCardParser setSwiftParserEnabled:enabled];
}

+ (SwiftAdaptiveCardParseResult *)parseWithPayload:(NSString *)payload {
    return [SwiftAdaptiveCardParser parseWithPayload:payload];
}

+ (BOOL)isParseResultSuccessful:(SwiftAdaptiveCardParseResult *)result {
    return (result.errors == nil || result.errors.count == 0);
}

@end
