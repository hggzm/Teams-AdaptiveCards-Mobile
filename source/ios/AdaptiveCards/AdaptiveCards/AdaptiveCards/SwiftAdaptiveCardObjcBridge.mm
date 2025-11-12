//
//  SwiftAdaptiveCardParserBridge.m
//  AdaptiveCards
//
//  Created by Hugo Gonzalez on 2/4/25.
//  Copyright © 2025 Microsoft. All rights reserved.
//

#import "SwiftAdaptiveCardObjcBridge.h"

#import "SharedAdaptiveCard.h"
#import "ParseResult.h"
#import "ACOAdaptiveCardParseResult.h"
#import "ACRParseWarningPrivate.h"
#import "ACOBaseCardElement.h"
#import "ACOBaseCardElementPrivate.h"
#import "ACOHostConfig.h"
#import "ACRView.h"
#import "ACRContentHoldingUIView.h"
#import "UtiliOS.h"

#if __has_include(<AdaptiveCards/AdaptiveCards-Swift.h>)
#define SWIFT_ADAPTIVE_CARDS_AVAILABLE 1
#import <AdaptiveCards/AdaptiveCards-Swift.h>
#else
#define SWIFT_ADAPTIVE_CARDS_AVAILABLE 0
#endif

// Import AdaptiveCardCustomElements package if available
#if __has_include(<AdaptiveCardCustomElements/AdaptiveCardCustomElements-Swift.h>)
#define ADAPTIVE_CARD_CUSTOM_ELEMENTS_AVAILABLE 1
#import <AdaptiveCardCustomElements/AdaptiveCardCustomElements-Swift.h>
#else
#define ADAPTIVE_CARD_CUSTOM_ELEMENTS_AVAILABLE 0
#endif

using namespace AdaptiveCards;

@implementation SwiftAdaptiveCardObjcBridge

+ (BOOL)canUseSwift {
#if SWIFT_ADAPTIVE_CARDS_AVAILABLE
    return YES;
#endif
    return NO;
}

+ (NSMutableArray * _Nullable)getWarningsFromParseResult:(id _Nullable)parseResult useSwift:(BOOL)useSwift {
    NSMutableArray *acrParseWarnings = [[NSMutableArray alloc] init];
    if (useSwift && [self canUseSwift]) {
        // Swift implementation
       SwiftAdaptiveCardParseResult *swiftResult = (SwiftAdaptiveCardParseResult *)parseResult;
       NSArray *swiftWarnings = [swiftResult warnings];
       if (swiftWarnings) {
           acrParseWarnings = [NSMutableArray arrayWithArray:swiftWarnings];
       }
    } else {
        // For C++ implementation, check the type of parseResult
        if ([parseResult isKindOfClass:[NSValue class]]) {
            // If it's an NSValue (which can store C++ pointers), extract the pointer
            std::shared_ptr<ParseResult> *cppResultPtr = (std::shared_ptr<ParseResult> *)[parseResult pointerValue];
            std::vector<std::shared_ptr<AdaptiveCardParseWarning>> parseWarnings = (*cppResultPtr)->GetWarnings();
            for (const auto &warning : parseWarnings) {
                ACRParseWarning *acrParseWarning = [[ACRParseWarning alloc] initWithParseWarning:warning];
                [acrParseWarnings addObject:acrParseWarning];
            }
        } else {
            NSLog(@"Error retrieving parsed result");
        }
    }
    return acrParseWarnings;
}

+ (BOOL)isSwiftParserEnabled {
    if ([self canUseSwift]) {
#if SWIFT_ADAPTIVE_CARDS_AVAILABLE
        return [SwiftAdaptiveCardParser isSwiftParserEnabled];
#endif
    }
    return NO;
}

+ (void)setSwiftParserEnabled:(BOOL)enabled {
    if ([self canUseSwift]) {
#if SWIFT_ADAPTIVE_CARDS_AVAILABLE
        [SwiftAdaptiveCardParser setSwiftParserEnabled:enabled];
#endif
    }
}

+ (SwiftAdaptiveCardParseResult * _Nonnull)parseWithPayload:(NSString *_Nonnull)payload {
#if SWIFT_ADAPTIVE_CARDS_AVAILABLE
    if ([self canUseSwift]) {
        return [SwiftAdaptiveCardParser parseWithPayload:payload];
    }
#endif
    // If Swift is not available, we need to return something
    // This should ideally never happen if canUseSwift is checked properly
    // but we need to satisfy the nonnull contract
    return (SwiftAdaptiveCardParseResult *)[[NSObject alloc] init];
}

+ (BOOL)isParseResultSuccessful:(SwiftAdaptiveCardParseResult *_Nonnull)result {
#if SWIFT_ADAPTIVE_CARDS_AVAILABLE
    // Check if there are any errors
    return (result.errors == nil || result.errors.count == 0);
#endif
    return NO;
}

#pragma mark - SwiftUI View Rendering Helpers

+ (BOOL)canRenderSwiftUIViews {
#if SWIFT_ADAPTIVE_CARDS_AVAILABLE
    if (@available(iOS 15.0, *)) {
        return YES;
    }
#endif
    return NO;
}

+ (UIView *_Nullable)renderCitationViewFromDictionary:(NSDictionary *_Nonnull)dictionary {
#if SWIFT_ADAPTIVE_CARDS_AVAILABLE
    if (![self canRenderSwiftUIViews]) {
        NSLog(@"[SwiftAdaptiveCardObjcBridge] SwiftUI views not available");
        return nil;
    }
    
    if (@available(iOS 15.0, *)) {
        // Use the CitationViewFactory from Swift
        UIView *citationView = [CitationViewFactory createCitationViewFrom:dictionary];
        if (citationView) {
            NSLog(@"[SwiftAdaptiveCardObjcBridge] Successfully created citation view");
            return citationView;
        } else {
            NSLog(@"[SwiftAdaptiveCardObjcBridge] Failed to create citation view from dictionary");
        }
    }
#endif
    return nil;
}

+ (BOOL)isValidCitationData:(NSDictionary *_Nonnull)dictionary {
#if SWIFT_ADAPTIVE_CARDS_AVAILABLE
    if (![self canRenderSwiftUIViews]) {
        return NO;
    }
    
    if (@available(iOS 15.0, *)) {
        return [CitationViewFactory isValidCitation:dictionary];
    }
#endif
    return NO;
}

#pragma mark - Generalized SwiftUI Custom Element Renderer

+ (UIView *_Nullable)renderSwiftUICustomElement:(ACOBaseCardElement *_Nonnull)element
                                      viewGroup:(UIView<ACRIContentHoldingView> *_Nullable)viewGroup
                                       rootView:(ACRView *_Nullable)rootView
                                     hostConfig:(ACOHostConfig *_Nullable)hostConfig {
#if SWIFT_ADAPTIVE_CARDS_AVAILABLE
    if (![self canRenderSwiftUIViews]) {
        NSLog(@"[SwiftAdaptiveCardObjcBridge] SwiftUI views not available");
        return nil;
    }
    
    if (@available(iOS 15.0, *)) {
        NSLog(@"[SwiftAdaptiveCardObjcBridge] Attempting to render SwiftUI custom element");
        
        UIView *swiftUIView = nil;
        
        // Try to extract custom element data from additionalProperty
        if ([element respondsToSelector:@selector(additionalProperty)]) {
            NSData *additionalPropertyData = [element additionalProperty];
            if (additionalPropertyData) {
                NSError *error = nil;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:additionalPropertyData
                                                                     options:0
                                                                       error:&error];
                if (json && !error) {
                    NSString *elementType = json[@"type"];
                    NSLog(@"[SwiftAdaptiveCardObjcBridge] Found custom element type: %@", elementType);
                    
                    // First check built-in SDK elements (like Citation)
                    if ([elementType isEqualToString:@"Citation"]) {
                        swiftUIView = [CitationViewFactory createCitationViewFrom:json];
                        
                        if (swiftUIView) {
                            NSLog(@"[SwiftAdaptiveCardObjcBridge] Successfully created Citation view");
                        } else {
                            NSLog(@"[SwiftAdaptiveCardObjcBridge] Failed to create Citation view");
                        }
                    }
                    // Then check AdaptiveCardCustomElements package registry
                    else {
#if ADAPTIVE_CARD_CUSTOM_ELEMENTS_AVAILABLE
                        if ([[CustomElementRegistry shared] supportsType:elementType]) {
                            swiftUIView = [[CustomElementRegistry shared] createViewFrom:json];
                            
                            if (swiftUIView) {
                                NSLog(@"[SwiftAdaptiveCardObjcBridge] Successfully created %@ view from package registry", elementType);
                            } else {
                                NSLog(@"[SwiftAdaptiveCardObjcBridge] Failed to create %@ view from package registry", elementType);
                            }
                        } else {
                            NSLog(@"[SwiftAdaptiveCardObjcBridge] Unknown custom element type: %@", elementType);
                        }
#else
                        NSLog(@"[SwiftAdaptiveCardObjcBridge] Unknown custom element type: %@ (package not available)", elementType);
#endif
                    }
                }
            }
        }
        
        // If we successfully created a SwiftUI view, configure it
        if (swiftUIView) {
            // Set up accessibility
            swiftUIView.isAccessibilityElement = YES;
            swiftUIView.accessibilityTraits = UIAccessibilityTraitButton;
            
            // Configure sizing
            swiftUIView.translatesAutoresizingMaskIntoConstraints = NO;
            
            // Set content priorities for proper layout
            [swiftUIView setContentHuggingPriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisVertical];
            [swiftUIView setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                          forAxis:UILayoutConstraintAxisVertical];
            
            // Prevent clipping
            swiftUIView.clipsToBounds = NO;
            
            // Add to view group if provided
            if (viewGroup && [viewGroup respondsToSelector:@selector(addArrangedSubview:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [viewGroup performSelector:@selector(addArrangedSubview:) withObject:swiftUIView];
#pragma clang diagnostic pop
            }
            
            return swiftUIView;
        } else {
            NSLog(@"[SwiftAdaptiveCardObjcBridge] Failed to create SwiftUI view");
        }
    }
#endif
    
    return nil;
}

+ (id)createSwiftUICustomElementRenderer
{
    return [[ACRSwiftUICustomElementRenderer alloc] init];
}

@end

#pragma mark - Inline SwiftUI Custom Element Renderer Implementation

@implementation ACRSwiftUICustomElementRenderer

+ (ACRCardElementType)elemType {
    // Use ACRCustom for all custom SwiftUI elements
    return ACRCustom;
}

- (UIView *)render:(UIView<ACRIContentHoldingView> *)viewGroup
          rootView:(ACRView *)rootView
            inputs:(NSMutableArray *)inputs
   baseCardElement:(ACOBaseCardElement *)acoElem
        hostConfig:(ACOHostConfig *)acoConfig {
    
    NSLog(@"[ACRSwiftUICustomElementRenderer] Rendering custom element");
    
    // Delegate to the SwiftAdaptiveCardObjcBridge for actual rendering
    UIView *swiftUIView = [SwiftAdaptiveCardObjcBridge renderSwiftUICustomElement:acoElem
                                                                        viewGroup:viewGroup
                                                                         rootView:rootView
                                                                       hostConfig:acoConfig];
    
    if (swiftUIView) {
        NSLog(@"[ACRSwiftUICustomElementRenderer] Successfully rendered custom element");
        return swiftUIView;
    }
    
    // Fallback: Create a simple label when SwiftUI rendering fails
    NSLog(@"[ACRSwiftUICustomElementRenderer] SwiftUI rendering failed, using fallback");
    
    UILabel *fallbackLabel = [[UILabel alloc] init];
    fallbackLabel.text = @"[Custom Element]";
    fallbackLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    fallbackLabel.textColor = [UIColor systemBlueColor];
    fallbackLabel.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.1];
    fallbackLabel.layer.cornerRadius = 4;
    fallbackLabel.layer.masksToBounds = YES;
    fallbackLabel.textAlignment = NSTextAlignmentCenter;
    fallbackLabel.translatesAutoresizingMaskIntoConstraints = NO;
    
    // Set intrinsic size constraints
    [fallbackLabel setContentHuggingPriority:UILayoutPriorityRequired
                                     forAxis:UILayoutConstraintAxisVertical];
    [fallbackLabel setContentHuggingPriority:UILayoutPriorityRequired
                                     forAxis:UILayoutConstraintAxisHorizontal];
    
    if (viewGroup && [viewGroup respondsToSelector:@selector(addArrangedSubview:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [viewGroup performSelector:@selector(addArrangedSubview:) withObject:fallbackLabel];
#pragma clang diagnostic pop
    }
    
    return fallbackLabel;
}

@end
