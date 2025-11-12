//
//  SwiftAdaptiveCardParserBridge.h
//  AdaptiveCards
//
//  Created by Hugo Gonzalez on 2/4/25.
//  Copyright © 2025 Microsoft. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "ACRBaseCardElementRenderer.h"

@class SwiftAdaptiveCardParseResult;
@class ACOBaseCardElement;
@class ACOHostConfig;
@class ACRView;
@protocol ACRIContentHoldingView;

@interface SwiftAdaptiveCardObjcBridge : NSObject

+ (NSMutableArray *_Nullable)getWarningsFromParseResult:(id _Nullable )parseResult useSwift:(BOOL)useSwift;

+ (BOOL)isSwiftParserEnabled;
+ (void)setSwiftParserEnabled:(BOOL)enabled;
+ (SwiftAdaptiveCardParseResult * _Nonnull)parseWithPayload:(NSString *_Nonnull)payload;
+ (BOOL)isParseResultSuccessful:(SwiftAdaptiveCardParseResult *_Nonnull)result;

// SwiftUI View Rendering Helpers
+ (BOOL)canRenderSwiftUIViews;
+ (UIView *_Nullable)renderCitationViewFromDictionary:(NSDictionary *_Nonnull)dictionary;
+ (BOOL)isValidCitationData:(NSDictionary *_Nonnull)dictionary;

// Generalized SwiftUI Custom Element Renderer
+ (UIView *_Nullable)renderSwiftUICustomElement:(ACOBaseCardElement *_Nonnull)element
                                      viewGroup:(UIView<ACRIContentHoldingView> *_Nullable)viewGroup
                                       rootView:(ACRView *_Nullable)rootView
                                     hostConfig:(ACOHostConfig *_Nullable)hostConfig;

// Helper to create SwiftUI custom element renderer instance
+ (id _Nonnull)createSwiftUICustomElementRenderer;

@end

#pragma mark - Inline SwiftUI Custom Element Renderer

/// Inline renderer for SwiftUI-based custom elements
/// Routes custom element types (Citation, etc.) to their appropriate SwiftUI view factories via the bridge
@interface ACRSwiftUICustomElementRenderer : NSObject <ACRIBaseCardElementRenderer>

@end
