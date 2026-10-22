//
//  ACRChoiceSetFilteredStyleView.mm
//  AdaptiveCards
//
//  Copyright © 2023 Microsoft. All rights reserved.
//

#import "ACRChoiceSetFilteredStyleView.h"
#import "ACOBaseCardElementPrivate.h"
#import "ACOBundle.h"
#import "ACOHostConfigPrivate.h"
#import "ACRActionDelegate.h"
#import "ACRBaseCardElementRenderer.h"
#import "ACRChoiceSetCompactStyleView.h"
#import "ACRInputLabelViewPrivate.h"
#import "ACRTypeaheadSearchParameters.h"
#import "ACRTypeaheadSearchViewControllerPrivate.h"
#import "ACRView.h"
#import "ChoiceInput.h"
#import "ChoiceSetInput.h"
#import "ChoicesData.h"
#import "HostConfig.h"
#import "UtiliOS.h"

using namespace AdaptiveCards;

static const CGFloat ACRChoiceSetFilteredStyleViewVerticalTextPadding = 6.0;
static const CGFloat ACRChoiceSetFilteredStyleViewAccessorySpacing = 8.0;

@interface ACRChoiceSetFilteredStyleView ()
- (void)updateSelectedValueLabel;
- (CGRect)selectedValueRectForBounds:(CGRect)bounds;
- (void)notifyInputLabelViewOfIntrinsicContentSizeChange;
@end

@implementation ACRChoiceSetFilteredStyleView {
    ACOFilteredDataSource *_filteredDataSource;
    ACOChoiceSetFilteredStyleValidator *_validator;
    ACOHostConfig *_hostConfig;
    ACOBaseCardElement *_inputElem;
    __weak ACRView *_rootView;
    UIButton *_navigationButton;
    NSString *_typeaheadViewTitle;
    ACRTypeaheadStateAllParameters *_searchStateParams;
    NSMutableArray<CompletionHandler> *_completionHandlers;
    UILabel *_selectedValueLabel;
    NSAttributedString *_selectedValueAttributedPlaceholder;
    NSString *_selectedValuePlaceholder;
    UIColor *_selectedValueTextColor;
    CGFloat _lastLayoutWidth;
}

- (instancetype)initWithInputChoiceSet:(ACOBaseCardElement *)acoElem
                              rootView:(ACRView *)rootView
                            hostConfig:(ACOHostConfig *)hostConfig
                     searchStateParams:(ACRTypeaheadStateAllParameters *)searchStateParams
                    typeaheadViewTitle:(NSString *)typeaheadViewTitle
{
    self = [super init];
    if (self) {
        std::shared_ptr<BaseCardElement> elem = [acoElem element];
        std::shared_ptr<ChoiceSetInput> choiceSet = std::dynamic_pointer_cast<ChoiceSetInput>(elem);
        _rootView = rootView;
        _inputElem = acoElem;
        _selectedValueTextColor = [super textColor];
        _hostConfig = hostConfig;
        _searchStateParams = searchStateParams;
        _typeaheadViewTitle = typeaheadViewTitle;
        _filteredDataSource = [[ACOFilteredDataSource alloc] init];
        _validator = [[ACOChoiceSetFilteredStyleValidator alloc] init:acoElem dataSource:_filteredDataSource];
        _completionHandlers = [[NSMutableArray alloc] init];

        // configure UITextField
        self.delegate = self;
        self.placeholder = _validator.placeHolder;
        UIColor *placeholderColor = [hostConfig getTextBlockColor:ACRDefault
                                                       textColor:ForegroundColor::Default
                                                    subtleOption:YES];
        self.attributedPlaceholder = [[NSAttributedString alloc] initWithString:self.placeholder ?: @""
                                                                     attributes:@{NSForegroundColorAttributeName : placeholderColor}];
        self.allowsEditingTextAttributes = NO;
        self.text = _validator.userInitialChoice;

        _selectedValueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _selectedValueLabel.numberOfLines = 0;
        _selectedValueLabel.lineBreakMode = NSLineBreakByWordWrapping;
        _selectedValueLabel.adjustsFontSizeToFitWidth = NO;
        _selectedValueLabel.isAccessibilityElement = NO;
        _selectedValueLabel.userInteractionEnabled = NO;
        [self addSubview:_selectedValueLabel];
        _lastLayoutWidth = -1.0;
        self.textColor = _selectedValueTextColor;

        // configure AdaptiveCards input handler
        self.id = [NSString stringWithCString:choiceSet->GetId().c_str()
                                     encoding:NSUTF8StringEncoding];
        self.isRequired = _validator.isRequired && !rootView.isRenderingInsideBottomSheet;
        self.hasValidationProperties = self.isRequired;
        self.accessibilityTraits = UIAccessibilityTraitButton;

        _navigationButton = [UIButton buttonWithType:UIButtonTypeCustom];
        self.showFilteredListControl = _navigationButton;
        [_navigationButton addTarget:self action:@selector(launchFullScreenTypeaheadSearchView) forControlEvents:UIControlEventTouchUpInside];
        self.rightView = _navigationButton;
        self.rightViewMode = UITextFieldViewModeAlways;
        self.showFilteredListControl = _navigationButton;

        ACRBaseCardElementRenderer *renderer = [[ACRRegistration getInstance] getRenderer:[NSNumber numberWithInt:(int)choiceSet->GetElementType()]];
        if (renderer && [renderer respondsToSelector:@selector(configure:rootView:baseCardElement:hostConfig:)]) {
            // configure input UI
            [renderer configure:self rootView:rootView baseCardElement:acoElem hostConfig:hostConfig];
        }
    }
    return self;
}

- (void)setText:(NSString *)text
{
    [super setText:text];
    [self updateSelectedValueLabel];
}

- (void)setFont:(UIFont *)font
{
    [super setFont:font];
    _selectedValueLabel.font = font;
    [self invalidateIntrinsicContentSize];
    [self setNeedsLayout];
    [self notifyInputLabelViewOfIntrinsicContentSizeChange];
}

- (void)setTextColor:(UIColor *)textColor
{
    _selectedValueTextColor = textColor;
    // The wrapping label is the visible value; hide UITextField's single-line copy.
    [super setTextColor:UIColor.clearColor];
    [self updateSelectedValueLabel];
}

- (void)setPlaceholder:(NSString *)placeholder
{
    _selectedValuePlaceholder = [placeholder copy];
    _selectedValueAttributedPlaceholder = nil;
    NSAttributedString *nativePlaceholder = nil;
    if (placeholder.length > 0) {
        nativePlaceholder = [[NSAttributedString alloc] initWithString:placeholder
                                                            attributes:@{NSForegroundColorAttributeName : UIColor.clearColor}];
    }
    [super setAttributedPlaceholder:nativePlaceholder];
    [self updateSelectedValueLabel];
}

- (void)setAttributedPlaceholder:(NSAttributedString *)attributedPlaceholder
{
    _selectedValueAttributedPlaceholder = [attributedPlaceholder copy];
    _selectedValuePlaceholder = [attributedPlaceholder.string copy];
    NSMutableAttributedString *nativePlaceholder = [attributedPlaceholder mutableCopy];
    if (nativePlaceholder.length > 0) {
        // UITextField draws its placeholder independently of drawPlaceholderInRect:.
        [nativePlaceholder addAttribute:NSForegroundColorAttributeName
                                 value:UIColor.clearColor
                                 range:NSMakeRange(0, nativePlaceholder.length)];
    }
    [super setAttributedPlaceholder:nativePlaceholder];
    [self updateSelectedValueLabel];
}

- (void)updateSelectedValueLabel
{
    if (!_selectedValueLabel) {
        return;
    }

    _selectedValueLabel.font = self.font;
    _selectedValueLabel.textAlignment = self.textAlignment;
    _selectedValueLabel.semanticContentAttribute = self.semanticContentAttribute;
    _selectedValueLabel.attributedText = nil;
    _selectedValueLabel.text = self.text;
    _selectedValueLabel.textColor = _selectedValueTextColor;
    if (!self.text.length) {
        if (_selectedValueAttributedPlaceholder) {
            _selectedValueLabel.attributedText = _selectedValueAttributedPlaceholder;
        } else {
            _selectedValueLabel.text = _selectedValuePlaceholder;
        }
    }

    self.accessibilityValue = self.text.length ? self.text : nil;
    [self invalidateIntrinsicContentSize];
    [self setNeedsLayout];
    [self notifyInputLabelViewOfIntrinsicContentSizeChange];
}

- (void)notifyInputLabelViewOfIntrinsicContentSizeChange
{
    UIView *ancestor = self.superview;
    while (ancestor && ![ancestor isKindOfClass:[ACRInputLabelView class]]) {
        ancestor = ancestor.superview;
    }
    [(ACRInputLabelView *)ancestor inputViewIntrinsicContentSizeDidChange];
}

- (CGRect)selectedValueRectForBounds:(CGRect)bounds
{
    CGRect contentRect = [super textRectForBounds:bounds];
    if (self.rightView) {
        CGRect accessoryRect = [self rightViewRectForBounds:bounds];
        if (CGRectIntersectsRect(contentRect, accessoryRect)) {
            if (CGRectGetMidX(accessoryRect) >= CGRectGetMidX(contentRect)) {
                CGFloat contentMaxX = CGRectGetMinX(accessoryRect) - ACRChoiceSetFilteredStyleViewAccessorySpacing;
                contentRect.size.width = MAX(0, contentMaxX - CGRectGetMinX(contentRect));
            } else {
                CGFloat contentMaxX = CGRectGetMaxX(contentRect);
                contentRect.origin.x = CGRectGetMaxX(accessoryRect) + ACRChoiceSetFilteredStyleViewAccessorySpacing;
                contentRect.size.width = MAX(0, contentMaxX - contentRect.origin.x);
            }
        }
    }

    contentRect.origin.y = ACRChoiceSetFilteredStyleViewVerticalTextPadding;
    contentRect.size.height = MAX(0, CGRectGetHeight(bounds) - 2 * ACRChoiceSetFilteredStyleViewVerticalTextPadding);
    return contentRect;
}

- (CGSize)intrinsicContentSize
{
    CGSize size = [super intrinsicContentSize];
    if (!_selectedValueLabel) {
        return size;
    }

    CGFloat width = CGRectGetWidth(self.bounds);
    if (width <= 0 && self.superview) {
        width = CGRectGetWidth(self.superview.bounds);
    }
    if (width <= 0) {
        return size;
    }

    CGRect sizingBounds = CGRectMake(0, 0, width, MAX(size.height, CGRectGetHeight(self.bounds)));
    CGRect contentRect = [self selectedValueRectForBounds:sizingBounds];
    CGSize labelSize = [_selectedValueLabel sizeThatFits:CGSizeMake(contentRect.size.width, CGFLOAT_MAX)];
    CGFloat expandedHeight = labelSize.height + 2 * ACRChoiceSetFilteredStyleViewVerticalTextPadding;
    return CGSizeMake(size.width, MAX(size.height, expandedHeight));
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    if (!_selectedValueLabel) {
        return;
    }

    CGFloat width = CGRectGetWidth(self.bounds);
    if (width != _lastLayoutWidth) {
        _lastLayoutWidth = width;
        [self invalidateIntrinsicContentSize];
        [self notifyInputLabelViewOfIntrinsicContentSizeChange];
    }
    _selectedValueLabel.frame = [self selectedValueRectForBounds:self.bounds];
    [self bringSubviewToFront:_selectedValueLabel];
    if (self.rightView) {
        [self bringSubviewToFront:self.rightView];
    }
}

// The wrapping label renders the value and placeholder; this remains a picker trigger.
- (void)drawTextInRect:(CGRect)rect
{
    (void)rect;
}

- (void)drawPlaceholderInRect:(CGRect)rect
{
    (void)rect;
}

- (void)launchFullScreenTypeaheadSearchView
{
    UIViewController *rootViewController = traverseResponderChainForUIViewController(_rootView);
    std::shared_ptr<BaseCardElement> elem = [_inputElem element];
    std::shared_ptr<ChoiceSetInput> choiceSet = std::dynamic_pointer_cast<ChoiceSetInput>(elem);
    std::shared_ptr<ChoicesData> choicesData = choiceSet->GetChoicesData();

    if (rootViewController &&
        choicesData->GetChoicesDataType().compare((AdaptiveCardSchemaKeyToString(AdaptiveCardSchemaKey::DataQuery))) == 0) {
        ACRTypeaheadSearchViewController *typeaheadSearchVC = [[ACRTypeaheadSearchViewController alloc] initWithInputChoiceSet:_inputElem
                                                                                                                      rootView:_rootView
                                                                                                                    hostConfig:_hostConfig
                                                                                                            filteredDataSource:_filteredDataSource
                                                                                                        filteredStyleValidator:_validator
                                                                                                            typeaheadViewTitle:_typeaheadViewTitle
                                                                                                             choiceSetDelegate:self
                                                                                                             searchStateParams:_searchStateParams];
        // check if client might want to launch the typeahead search view
        if ([_rootView.acrActionDelegate respondsToSelector:@selector(shouldLaunchTypeaheadSearchViewController:)]) {
            BOOL shouldPresentVC = [_rootView.acrActionDelegate shouldLaunchTypeaheadSearchViewController:typeaheadSearchVC];
            if (shouldPresentVC) {
                UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:typeaheadSearchVC];
                navController.modalPresentationStyle = UIModalPresentationFullScreen;
                [rootViewController presentViewController:navController animated:YES completion:nil];
            }
        }
    }
}

- (void)navigateToTypeaheadSearchView:(UIButton *)button
{
    [self launchFullScreenTypeaheadSearchView];
}

#pragma mark - UITextFieldDelegate Methods

- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField
{
    [self launchFullScreenTypeaheadSearchView];
    return NO;
}

/// configures position of showFilteredListControl
- (CGRect)rightViewRectForBounds:(CGRect)bounds
{
    CGRect newBounds = [super rightViewRectForBounds:bounds];
    newBounds.origin.x = newBounds.origin.x - self.layoutMargins.right;
    return newBounds;
}

#pragma mark - ACRIBaseInputHandler Methods

- (void)setFocus:(BOOL)shouldBecomeFirstResponder view:(UIView *)view
{
    self.accessibilityLabel = view.accessibilityLabel;
    if (shouldBecomeFirstResponder) {
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, self);
    } else {
        [view resignFirstResponder];
    }
}

- (BOOL)validate:(NSError * __autoreleasing *)error
{
    return [_validator isValid:self.text];
}

- (void)getInput:(NSMutableDictionary *)dictionary
{
    dictionary[self.id] = [_validator getValue:self.text];
}

- (void)addObserverWithCompletion:(CompletionHandler)completion
{
    [_completionHandlers addObject:completion];
}

- (void)notifyObservers {
    for(CompletionHandler completion in _completionHandlers) {
        completion();
    }
}

- (void)resetInput
{
    self.text = _validator.userInitialChoice;
}

#pragma mark - ACRChoiceSetTypeaheadSearchDelegate Methods

- (void)updateSelectedChoiceInTextField:(NSString *)text
{
    self.text = text;
    [self notifyObservers];
}

- (NSString *)getSelectedText
{
    return self.text;
}

- (NSString *)getChoiceSetId
{
    return self.id;
}

@synthesize hasValidationProperties;
@synthesize hasVisibilityChanged;
@synthesize isRequired;
@synthesize id;

@end
