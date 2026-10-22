//
//  ACRChoiceSetFilteredStyleViewTests.cpp
//  AdaptiveCardsTests
//
//  Created by Jyoti Kukreja on 26/01/23.
//  Copyright © 2023 Microsoft. All rights reserved.
//

#import "ACOBaseCardElement.h"
#import "ACOBaseCardElementPrivate.h"
#import "ACOHostConfigPrivate.h"
#import "ACRChoiceSetFilteredStyleView.h"
#import "ACRContrastTestUtils.h"
#import "ACRInputLabelViewPrivate.h"
#import "ACRMockViews.h"
#import "ChoiceInput.h"
#import "ChoiceSetInput.h"
#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>

@interface ACRChoiceSetLayoutChangeTestDelegate : NSObject <ACRActionDelegate>
@property (nonatomic, assign) NSUInteger layoutChangeCount;
@property (nonatomic, assign) CGRect oldFrame;
@property (nonatomic, assign) CGRect newFrame;
@end

@implementation ACRChoiceSetLayoutChangeTestDelegate

- (void)didFetchUserResponses:(ACOAdaptiveCard *)card action:(ACOBaseActionElement *)action
{
    (void)card;
    (void)action;
}

- (void)didChangeViewLayout:(CGRect)oldFrame newFrame:(CGRect)newFrame
{
    self.layoutChangeCount++;
    self.oldFrame = oldFrame;
    self.newFrame = newFrame;
}

@end

@interface ACRChoiceSetFilteredStyleViewTests : XCTestCase

@end

@implementation ACRChoiceSetFilteredStyleViewTests {
    MockACRView *_rootView;
    ACOBaseCardElement *_acoElem;
    ACOHostConfig *_hostConfig;
}

- (void)setUp
{
    _rootView = [[MockACRView alloc] initWithFrame:CGRectMake(0, 0, 20, 30)];
    std::shared_ptr<ChoiceSetInput> choiceSet = std::make_shared<ChoiceSetInput>();
    choiceSet->SetPlaceholder("Please choose");
    _acoElem = [[ACOBaseCardElement alloc] initWithBaseCardElement:choiceSet];
    _hostConfig = [[ACOHostConfig alloc] init];
}

- (void)testFilteredStyleViewInit
{
    ACRChoiceSetFilteredStyleView *filteredView = [[ACRChoiceSetFilteredStyleView alloc] initWithInputChoiceSet:_acoElem rootView:_rootView hostConfig:_hostConfig searchStateParams:nil typeaheadViewTitle:@"typeahead"];
    XCTAssertNotNil(filteredView.showFilteredListControl);
    NSString *selectedText = [filteredView getSelectedText];
    XCTAssertEqual(selectedText.length, 0);
    BOOL res = [filteredView validate:nil];
    XCTAssertTrue(res);
    NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] init];
    [filteredView getInput:dictionary];
    [filteredView updateSelectedChoiceInTextField:@"Option 1"];
    selectedText = [filteredView getSelectedText];
    XCTAssertEqualObjects(selectedText, @"Option 1");
    res = [filteredView validate:nil];
    XCTAssertFalse(res);
}

- (void)testLongSelectedChoiceWrapsAndKeepsSubmittedValue
{
    NSString *longTitle = @"MultiGame - Aurora expedition across the Crimson Nebula, including its campaign, mission, and seasonal rewards";
    std::shared_ptr<AdaptiveCards::ChoiceSetInput> choiceSet = std::make_shared<AdaptiveCards::ChoiceSetInput>();
    choiceSet->SetId(std::string("multiGameChoices"));
    choiceSet->SetPlaceholder("Please choose");
    std::shared_ptr<AdaptiveCards::ChoiceInput> choice = std::make_shared<AdaptiveCards::ChoiceInput>();
    choice->SetTitle(std::string([longTitle UTF8String]));
    choice->SetValue(std::string("synthetic-multigame-01"));
    choiceSet->GetChoices().push_back(choice);
    ACOBaseCardElement *acoElem = [[ACOBaseCardElement alloc] initWithBaseCardElement:choiceSet];
    ACRChoiceSetFilteredStyleView *filteredView = [[ACRChoiceSetFilteredStyleView alloc] initWithInputChoiceSet:acoElem rootView:_rootView hostConfig:_hostConfig searchStateParams:nil typeaheadViewTitle:@"typeahead"];
    filteredView.frame = CGRectMake(0, 0, 354, 34);

    CGFloat initialHeight = filteredView.intrinsicContentSize.height;
    [filteredView updateSelectedChoiceInTextField:longTitle];
    CGSize selectedSize = filteredView.intrinsicContentSize;

    XCTAssertGreaterThan(selectedSize.height, initialHeight);
    XCTAssertEqualObjects(filteredView.text, longTitle);
    XCTAssertEqualObjects(filteredView.accessibilityValue, longTitle);
    XCTAssertTrue((filteredView.accessibilityTraits & UIAccessibilityTraitButton) != 0);
    XCTAssertFalse([filteredView textFieldShouldBeginEditing:filteredView]);

    NSMutableDictionary *inputs = [NSMutableDictionary new];
    [filteredView getInput:inputs];
    XCTAssertEqualObjects(inputs[@"multiGameChoices"], @"synthetic-multigame-01");
}

- (void)testLongSelectedChoiceGrowthPropagatesToCardAndHost
{
    NSString *longTitle = @"MultiGame - Aurora expedition across the Crimson Nebula, including its campaign, mission, and seasonal rewards";
    std::shared_ptr<ChoiceSetInput> choiceSet = std::make_shared<ChoiceSetInput>();
    choiceSet->SetId(std::string("multiGameChoices"));
    choiceSet->SetPlaceholder("Please choose");
    std::shared_ptr<ChoiceInput> choice = std::make_shared<ChoiceInput>();
    choice->SetTitle(std::string([longTitle UTF8String]));
    choice->SetValue(std::string("synthetic-multigame-01"));
    choiceSet->GetChoices().push_back(choice);
    ACOBaseCardElement *acoElem = [[ACOBaseCardElement alloc] initWithBaseCardElement:choiceSet];

    _rootView.frame = CGRectMake(0, 0, 354, 0);
    ACRColumnView *column = [[ACRColumnView alloc] initWithFrame:CGRectMake(0, 0, 354, 0)];
    ACRChoiceSetFilteredStyleView *filteredView = [[ACRChoiceSetFilteredStyleView alloc] initWithInputChoiceSet:acoElem rootView:_rootView hostConfig:_hostConfig searchStateParams:nil typeaheadViewTitle:@"typeahead"];
    filteredView.frame = CGRectMake(0, 0, 354, 34);
    ACRInputLabelView *inputLabelView = [[ACRInputLabelView alloc] initInputLabelView:_rootView
                                                                            acoConfig:_hostConfig
                                                               adaptiveInputElement:choiceSet
                                                                          inputView:filteredView
                                                                 accessibilityItem:filteredView
                                                                          viewGroup:column
                                                                         dataSource:nil];
    [column addArrangedSubview:inputLabelView withAreaName:nil];
    [_rootView addArrangedSubview:column withAreaName:nil];

    ACRChoiceSetLayoutChangeTestDelegate *actionDelegate = [[ACRChoiceSetLayoutChangeTestDelegate alloc] init];
    _rootView.acrActionDelegate = actionDelegate;

    CGFloat initialColumnHeight = column.intrinsicContentSize.height;
    CGFloat initialCardHeight = _rootView.intrinsicContentSize.height;
    _rootView.frame = CGRectMake(0, 0, 354, initialCardHeight);
    [filteredView updateSelectedChoiceInTextField:longTitle];

    XCTAssertGreaterThan(column.intrinsicContentSize.height, initialColumnHeight);
    XCTAssertGreaterThan(_rootView.intrinsicContentSize.height, initialCardHeight);
    XCTAssertEqual(actionDelegate.layoutChangeCount, 1);
    XCTAssertEqualWithAccuracy(actionDelegate.oldFrame.size.height, initialCardHeight, 0.01);
    XCTAssertEqualWithAccuracy(actionDelegate.newFrame.size.height, _rootView.intrinsicContentSize.height, 0.01);

    [filteredView updateSelectedChoiceInTextField:longTitle];
    XCTAssertEqual(actionDelegate.layoutChangeCount, 1);
}

- (void)testPlaceholderMeetsContrastRequirement
{
    ACRChoiceSetFilteredStyleView *filteredView = [[ACRChoiceSetFilteredStyleView alloc] initWithInputChoiceSet:_acoElem rootView:_rootView hostConfig:_hostConfig searchStateParams:nil typeaheadViewTitle:@"typeahead"];
    UIColor *placeholderColor = [filteredView.attributedPlaceholder attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:nil];
    UITraitCollection *lightTraits = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight];
    UIColor *backgroundColor = [UIColor.systemGroupedBackgroundColor resolvedColorWithTraitCollection:lightTraits];

    XCTAssertGreaterThanOrEqual(ACRContrastRatio(placeholderColor, backgroundColor, lightTraits), 4.5);
}

@end
