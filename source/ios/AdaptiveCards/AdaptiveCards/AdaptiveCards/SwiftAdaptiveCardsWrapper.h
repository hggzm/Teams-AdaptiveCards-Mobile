//
//  SwiftAdaptiveCardsWrapper.h
//  AdaptiveCards
//
//  Created by Hugo Gonzalez on 11/25/25.
//  Copyright © 2025 Microsoft. All rights reserved.
//

#import <Foundation/Foundation.h>

@class SwiftAdaptiveCardParseResult;
@class SwiftAdaptiveCardParser;

NS_ASSUME_NONNULL_BEGIN

/// Wrapper to expose Swift Package types to Objective-C++
@interface SwiftAdaptiveCardsWrapper : NSObject

/// Get warnings array from Swift parse result
+ (NSArray * _Nullable)getWarningsFromSwiftResult:(SwiftAdaptiveCardParseResult *)result;

/// Check if Swift parser is enabled
+ (BOOL)isSwiftParserEnabled;

/// Set Swift parser enabled state
+ (void)setSwiftParserEnabled:(BOOL)enabled;

/// Parse payload with Swift parser
+ (SwiftAdaptiveCardParseResult *)parseWithPayload:(NSString *)payload;

/// Check if parse result is successful
+ (BOOL)isParseResultSuccessful:(SwiftAdaptiveCardParseResult *)result;

@end

NS_ASSUME_NONNULL_END
