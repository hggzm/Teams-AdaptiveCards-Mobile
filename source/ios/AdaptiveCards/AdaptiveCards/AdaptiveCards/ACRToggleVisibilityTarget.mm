//
//  ACRToggleVisibilityTarget
//  ACRToggleVisibilityTarget.mm
//
//  Copyright © 2018 Microsoft. All rights reserved.
//

#import "ACRToggleVisibilityTarget.h"
#import "ACOBaseActionElementPrivate.h"
#import "ACOHostConfigPrivate.h"
#import "ACOVisibilityManager.h"
#import "ACRContentStackView.h"
#import "ACRRendererPrivate.h"
#import "ACRView.h"
#import "BaseActionElement.h"
#import "ToggleVisibilityTarget.h"
#import "ACRIFeatureFlagResolver.h"
#import "ACRRegistration.h"

@implementation ACRToggleVisibilityTarget {
    ACOHostConfig *_config;
    __weak ACRView *_rootView;
    ACOBaseActionElement *_actionElement;
}

- (instancetype)initWithActionElement:(ACOBaseActionElement *)actionElement
                               config:(ACOHostConfig *)config
                             rootView:(ACRView *)rootView
{
    self = [super init];
    if (self) {
        _config = config;
        _rootView = rootView;
        _actionElement = actionElement;
    }
    return self;
}

- (void)doSelectAction
{
    NSObject<ACRIFeatureFlagResolver> *featureFlagResolver = [[ACRRegistration getInstance] getFeatureFlagResolver];
    BOOL isSplitButtonEnabled = [featureFlagResolver boolForFlag:@"isSplitButtonEnabled"] ?: NO;
    isSplitButtonEnabled = isSplitButtonEnabled &&
    [_rootView.acrActionDelegate respondsToSelector:@selector(showBottomSheetForSplitButton:completion:)];
    /// Perform default implementation if:
    /// 1. If split button is disabled or
    /// 2. There are no menuactions or
    /// 3.a. There are menuactions and
    /// 3.b. (If the action is from bottom sheet) or (If there's no implementation of showBottomSheetForSplitButton method in delegate)
    if (!isSplitButtonEnabled ||
        _actionElement.menuActions.count <= 0 ||
        (_actionElement.isActionFromSplitButtonBottomSheet && _actionElement.menuActions.count > 0))
    {
        [self doSelectActionWithAction:_actionElement];
    }
    else
    {
        NSArray<ACOBaseActionElement *> *menuActions = [@[ _actionElement ] arrayByAddingObjectsFromArray:_actionElement.menuActions];
        __weak __typeof(self) weakSelf = self;
        [_rootView.acrActionDelegate showBottomSheetForSplitButton: menuActions completion:^(ACOBaseActionElement *acoElement) {
            __strong __typeof(self) strongSelf = weakSelf;
            if (acoElement.type == ACRToggleVisibility)
            {
                [strongSelf doSelectActionWithAction:acoElement];
            }
            [strongSelf->_rootView.acrActionDelegate didFetchUserResponses:[strongSelf->_rootView card] action:acoElement];
        }];
    }

    [_rootView.acrActionDelegate didFetchUserResponses:[_rootView card] action:_actionElement];
}

- (void) doSelectActionWithAction:(ACOBaseActionElement *)actionElement
{
    NSMutableSet<id<ACOIVisibilityManagerFacade>> *facades = [[NSMutableSet alloc] init];
    std::shared_ptr<BaseActionElement> elem = [actionElement element];
    std::shared_ptr<ToggleVisibilityAction> action = std::dynamic_pointer_cast<ToggleVisibilityAction>(elem);
    for (const auto &target : action->GetTargetElements()) {
        NSString *hashString = [NSString stringWithCString:target->GetElementId().c_str() encoding:NSUTF8StringEncoding];
        NSUInteger tag = hashString.hash;
        UIView *view = [_rootView viewWithTag:tag];
        BOOL bHide = NO;

        id<ACOIVisibilityManagerFacade> facade = [_rootView.context retrieveVisiblityManagerWithTag:view.tag];
        [facades addObject:facade];

        AdaptiveCards::IsVisible toggleEnum = target->GetIsVisible();
        if (toggleEnum == AdaptiveCards::IsVisibleToggle) {
            BOOL isHidden = view.isHidden;
            bHide = !isHidden;
        } else if (toggleEnum == AdaptiveCards::IsVisibleTrue) {
            bHide = NO;
        } else {
            bHide = YES;
        }

        if (facade) {
            if (bHide) {
                [facade hideView:view];
            } else {
                [facade unhideView:view];
            }
        }
    }

    for (id<ACOIVisibilityManagerFacade> viewToUpdateVisibility in facades) {
        [viewToUpdateVisibility updatePaddingVisibility];
    }

    // Re-measure the host after a ToggleVisibility expand/collapse (fixes #812389686).
    //
    // ShowCard already tells the host to re-measure (didChangeVisibility: /
    // didChangeViewLayout:) so a self-sizing host cell grows with the expanded
    // content. ToggleVisibility did not, so expanding a tall hidden Container
    // left the host at its collapsed height: the content was clipped (no scroll
    // region created) and overflowed its host cell, overlapping the next card
    // (z-order).
    //
    // 1. Recompute + invalidate the cached intrinsic content size from each
    //    affected host up to the root view. ACRColumnView caches its height in
    //    combinedContentSize (returned by intrinsicContentSize); the toggle path
    //    updates it incrementally via increaseIntrinsicContentSize: but never
    //    invalidates it, so UIKit keeps the stale collapsed size. The bottom-up
    //    walk recomputes from the visible arranged subviews (idempotent) and
    //    invalidates so the layout engine re-queries the grown size.
    for (id<ACOIVisibilityManagerFacade> facade in facades) {
        if (![facade isKindOfClass:[ACRContentStackView class]]) {
            continue;
        }
        UIView *node = (ACRContentStackView *)facade;
        while (node) {
            if ([node isKindOfClass:[ACRContentStackView class]]) {
                [(ACRContentStackView *)node updateIntrinsicContentSize];
                [node invalidateIntrinsicContentSize];
                [node setNeedsLayout];
            }
            if (node == _rootView) {
                break;
            }
            node = node.superview;
        }
    }

    // 2. Ask the host to re-measure the card, exactly as ShowCard does. Report
    //    the root view's current frame as the old size and its recomputed
    //    intrinsic height as the new size so a self-sizing cell can grow/shrink.
    if (_rootView &&
        [_rootView.acrActionDelegate respondsToSelector:@selector(didChangeViewLayout:newFrame:)]) {
        CGRect oldFrame = _rootView.frame;
        CGRect newFrame = oldFrame;
        newFrame.size.height = _rootView.intrinsicContentSize.height;
        if (ABS(newFrame.size.height - oldFrame.size.height) > 0.5) {
            [_rootView.acrActionDelegate didChangeViewLayout:oldFrame newFrame:newFrame];
        }
    }

    // Post an accessibility layout-changed notification so VoiceOver re-scans the
    // toggled content and does not lose focus.
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
}

@end
