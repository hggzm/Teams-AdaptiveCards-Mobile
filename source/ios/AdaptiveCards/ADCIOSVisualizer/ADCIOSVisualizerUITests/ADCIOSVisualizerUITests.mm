//
//  ADCIOSVisualizerUITests.m
//  ADCIOSVisualizerUITests
//
//  Created by jwoo on 6/2/17.
//  Copyright © 2017 Microsoft. All rights reserved.
//

#import "AdaptiveCards/ACOHostConfigPrivate.h"
#import <AdaptiveCards/AdaptiveCards.h>
#import <XCTest/XCTest.h>

/// Upper bound for popover/bottom-sheet transitions. Generous on purpose: this is a
/// ceiling for a wait that normally returns in well under a second, not a fixed delay.
static const NSTimeInterval kACRPopoverTimeout = 10.0;
#include <string>

@interface ADCIOSVisualizerUITests : XCTestCase

@end

@implementation ADCIOSVisualizerUITests {
    XCUIApplication *testApp;
}

- (void)setUp
{
    [super setUp];
    // Put setup code here. This method is called before the invocation of each test method in the class.
    // In UI tests it is usually best to stop immediately when a failure occurs.
    self.continueAfterFailure = NO;
    // UI tests must launch the application that they test. Doing this in setup will make sure it happens for each test method.
    // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.

    if (testApp == nil) {
        testApp = [[XCUIApplication alloc] init];
        testApp.launchArguments = [NSArray arrayWithObject:@"ui-testing"];
        [testApp launch];
    }

    [self resetTestEnvironment];
}

- (void)tearDown
{
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (void)resetTestEnvironment
{
    XCUIElementQuery *buttons = testApp.buttons;
    const int cardDepthLimit = 3;

    // try to find Back button and tap it while it appears
    XCUIElement *backButton = buttons[@"Back"];

    int backButtonPressedCount = 0;
    while ([backButton exists] && backButtonPressedCount < cardDepthLimit) {
        [backButton tap];
        backButton = buttons[@"Back"];
        ++backButtonPressedCount;
    }

    // tap on delete all cards button
    [buttons[@"Delete All Cards"] tap];
}

- (void)openCardForVersion:(NSString *)version forCardType:(NSString *)type withCardName:(NSString *)scenarioName
{
    XCUIElementQuery *buttons = testApp.buttons;
    [buttons[version] tap];
    [buttons[type] tap];

    XCUIElementQuery *tables = testApp.tables;
    XCUIElement *table = [tables elementBoundByIndex:1];
    XCUIElementQuery *cell = [[table staticTexts] matchingIdentifier:scenarioName];

    // Interact with it when visible
    [[cell elementBoundByIndex:0] tap];
}

- (NSDictionary *)parseJsonToDictionary:(NSString *)json
{
    NSData *jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSError *jsonError;
    NSDictionary *parsedJsonData = [NSJSONSerialization JSONObjectWithData:jsonData
                                                                   options:NSJSONWritingPrettyPrinted
                                                                     error:&jsonError];
    return parsedJsonData;
}

- (NSDictionary *)getInputsFromResultsDictionary:(NSDictionary *)results
{
    return [results objectForKey:@"inputs"];
}

- (NSString *)getInputsString
{
    XCUIElement *resultsTextView = [testApp.staticTexts elementMatchingType:XCUIElementTypeAny identifier:@"SubmitActionRetrievedResults"];
    return resultsTextView.label;
}

- (bool)verifyInputsAreEmpty
{
    return [@" " isEqualToString:[self getInputsString]];
}

- (void)tapOnButtonWithText:(NSString *)buttonText
{
    XCUIElementQuery *buttons = testApp.buttons;
    XCUIElement *button = buttons[buttonText];
    XCTAssertTrue([button exists]);
    [button tap];
}

- (void)verifyInput:(NSString *)inputId matchesExpectedValue:(NSString *)expectedValue inInputSet:(NSDictionary *)inputDictionary
{
    id inputValue = [inputDictionary objectForKey:inputId];

    XCTAssertTrue([expectedValue isEqualToString:inputValue], @"Input Id: %@ has value: %@ for expected value: %@", inputId, inputValue, expectedValue);
}

- (void)verifyNumberInput:(NSString *)inputId matchesExpectedValue:(NSString *)expectedValue inInputSet:(NSDictionary *)inputDictionary
{
    id inputValue = [[inputDictionary objectForKey:inputId] stringValue];

    XCTAssertTrue([expectedValue isEqualToString:inputValue], @"Input Id: %@ has value: %@ for expected value: %@", inputId, inputValue, expectedValue);
}

- (void)setDateOnInputDateWithId:(NSString *)Id andLabel:(NSString *)label forYear:(NSString *)year month:(NSString *)month day:(NSString *)day
{
    [self tapOnButtonWithText:Id];

    XCUIElement *enterTheDueDateDatePicker = testApp.datePickers[label];

    [[enterTheDueDateDatePicker.pickerWheels elementBoundByIndex:0] adjustToPickerWheelValue:month];

    [[enterTheDueDateDatePicker.pickerWheels elementBoundByIndex:1] adjustToPickerWheelValue:day];

    [[enterTheDueDateDatePicker.pickerWheels elementBoundByIndex:2] adjustToPickerWheelValue:year];

    // Dismiss the date picker
    [testApp.toolbars[@"Toolbar"].buttons[@"Done"] tap];
}

- (void)testSmokeTestActivityUpdateDate
{
    [self openCardForVersion:@"v1.5" forCardType:@"Scenarios" withCardName:@"ActivityUpdate.json"];

    [self tapOnButtonWithText:@"Set due date"];

    [self setDateOnInputDateWithId:@"dueDate"
                          andLabel:@"Enter the due date"
                           forYear:@"2021"
                             month:@"July"
                               day:@"15"];

    [self tapOnButtonWithText:@"Send"];

    NSString *resultsString = [self getInputsString];
    NSDictionary *resultsDictionary = [self parseJsonToDictionary:resultsString];
    NSDictionary *inputs = [self getInputsFromResultsDictionary:resultsDictionary];

    [self verifyInput:@"dueDate" matchesExpectedValue:@"2021-07-15" inInputSet:inputs];
}

- (void)testSmokeTestActivityUpdateComment
{
    [self openCardForVersion:@"v1.5" forCardType:@"Scenarios" withCardName:@"ActivityUpdate.json"];

    XCUIElementQuery *buttons = testApp.buttons;
    [buttons[@"Comment"] tap];

    XCUIElementQuery *tables = testApp.tables;
    XCUIElement *chatWindow = tables[@"ChatWindow"];

    XCUIElement *commentTextInput = [chatWindow.textViews elementMatchingType:XCUIElementTypeAny identifier:@"comment"];
    [commentTextInput tap];
    [NSThread sleepForTimeInterval:0.5]; // Wait for keyboard focus
    [commentTextInput typeText:@"A comment"];

    [buttons[@"Done"] tap];
    [buttons[@"OK"] tap];

    NSString *resultsString = [self getInputsString];
    NSDictionary *resultsDictionary = [self parseJsonToDictionary:resultsString];
    NSDictionary *inputs = [self getInputsFromResultsDictionary:resultsDictionary];

    [self verifyInput:@"comment" matchesExpectedValue:@"A comment" inInputSet:inputs];
}

- (void)testFocusOnValidationFailure
{
    [self openCardForVersion:@"v1.3" forCardType:@"Elements" withCardName:@"Input.Text.ErrorMessage.json"];

    [self tapOnButtonWithText:@"Submit"];

    XCUIElement *chatWindow = testApp.tables[@"ChatWindow"];
    XCUIElement *firstInput = [chatWindow.textFields elementMatchingType:XCUIElementTypeAny identifier:@"Required Input.Text *, This is a required input,"];

    XCTAssertTrue([firstInput valueForKey:@"hasKeyboardFocus"], "First input is not selected");
}

- (void)testLongPressAndDragRaiseNoEventInContainers
{
    [self openCardForVersion:@"v1.5" forCardType:@"Tests" withCardName:@"Container.ScrollableSelectableList.json"];

    XCUIElement *chatWindow = testApp.tables[@"ChatWindow"];

    XCUIElementQuery *container1Query = [chatWindow.buttons matchingIdentifier:@"OneNote,Dolor Sit Amet,Projects > LoremIpsum"];

    XCUIElementQuery *container2Query = [chatWindow.buttons matchingIdentifier:@"OneNote,OneNote File 2,Documents > Test"];

    // For some unknown reason this test succeeds on a mackbook but not in
    // a mac mini (xcode and emulator versions match), so we have to add a
    // small wait time to avoid the long press behaving as a tap
    [NSThread sleepForTimeInterval:1];

    // Execute a drag from the 4th element to the 2nd element
    [container1Query.element pressForDuration:1 thenDragToElement:container2Query.element];
    // assert the submit textview has a blank space, thus the submit event was not raised
    XCTAssert([self verifyInputsAreEmpty]);
}

- (void)verifyChoiceSetInput:(NSDictionary<NSString *, NSString *> *)expectedValue application:(XCUIApplication *)app
{
    NSData *expectedData = [NSJSONSerialization dataWithJSONObject:expectedValue options:NSJSONWritingPrettyPrinted error:nil];
    XCUIElement *queryResult = app.scrollViews.staticTexts[@"ACRUserResponse"];
    NSArray<NSString *> *components = [queryResult.label componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *stringWithNoWhiteSpaces = [components componentsJoinedByString:@""];
    NSString *expectedString = [[NSString alloc] initWithData:expectedData encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *expectedComponents = [expectedString componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *expectedStringWithNoWhiteSpaces = [expectedComponents componentsJoinedByString:@""];
    XCTAssertTrue([stringWithNoWhiteSpaces isEqualToString:expectedStringWithNoWhiteSpaces]);
}

- (void)testCanGatherDefaultValuesFromChoiceInputSet
{
    [self openCardForVersion:@"v1.3" forCardType:@"Elements" withCardName:@"Input.ChoiceSet.json"];

    XCUIElement *chatWindow = testApp.tables[@"ChatWindow"];
    [chatWindow swipeUp];

    XCUIElementQuery *buttons = testApp.buttons;
    [buttons[@"OK"] tap];

    NSString *resultsString = [self getInputsString];
    NSDictionary *resultsDictionary = [self parseJsonToDictionary:resultsString];
    NSDictionary *inputs = [self getInputsFromResultsDictionary:resultsDictionary];

    [self verifyInput:@"myColor" matchesExpectedValue:@"1" inInputSet:inputs];
    [self verifyInput:@"myColor2" matchesExpectedValue:@"1" inInputSet:inputs];
    [self verifyInput:@"myColor3" matchesExpectedValue:@"1,3" inInputSet:inputs];
    [self verifyInput:@"myColor4" matchesExpectedValue:@"1" inInputSet:inputs];
}

- (void)testCanGatherCorrectValuesFromCompactChoiceSet
{
    [self openCardForVersion:@"v1.3" forCardType:@"Elements" withCardName:@"Input.ChoiceSet.json"];

    XCUIElement *chatWindow = testApp.tables[@"ChatWindow"];
    [chatWindow /*@START_MENU_TOKEN@*/.buttons[@"myColor"] /*[[".cells.buttons[@\"myColor\"]",".buttons[@\"myColor\"]"],[[[-1,1],[-1,0]]],[0]]@END_MENU_TOKEN@*/ tap];

    XCUIElementQuery *tablesQuery = testApp.tables;
    [tablesQuery.cells[@"myColor, Blue"].staticTexts[@"Blue"] tap];

    [chatWindow swipeUp];

    XCUIElementQuery *buttons = testApp.buttons;
    [buttons[@"OK"] tap];

    NSString *resultsString = [self getInputsString];
    NSDictionary *resultsDictionary = [self parseJsonToDictionary:resultsString];
    NSDictionary *inputs = [self getInputsFromResultsDictionary:resultsDictionary];

    [self verifyInput:@"myColor" matchesExpectedValue:@"3" inInputSet:inputs];
    [self verifyInput:@"myColor2" matchesExpectedValue:@"1" inInputSet:inputs];
    [self verifyInput:@"myColor3" matchesExpectedValue:@"1,3" inInputSet:inputs];
    [self verifyInput:@"myColor4" matchesExpectedValue:@"1" inInputSet:inputs];
}

- (void)testCanGatherCorrectValuesFromExpandedRadioButton
{
    [self openCardForVersion:@"v1.3" forCardType:@"Elements" withCardName:@"Input.ChoiceSet.json"];

    XCUIElement *chatWindow = testApp.tables[@"ChatWindow"];
    [chatWindow.tables[@"myColor2"].staticTexts[@"myColor2, Blue"] tap];
    [chatWindow.tables[@"myColor2"].staticTexts[@"myColor2, Green"] tap];
    [chatWindow /*@START_MENU_TOKEN@*/.tables[@"myColor3"].staticTexts[@"myColor3, Red"] /*[[".cells.tables[@\"myColor3\"]",".cells[@\"Empty list, Red\"]",".staticTexts[@\"Red\"]",".staticTexts[@\"myColor3, Red\"]",".tables[@\"myColor3\"]"],[[[-1,4,1],[-1,0,1]],[[-1,3],[-1,2],[-1,1,2]],[[-1,3],[-1,2]]],[0,0]]@END_MENU_TOKEN@*/ tap];

    [chatWindow swipeUp];

    // Execute a drag from the 4th element to the 2nd element
    XCUIElementQuery *buttons = testApp.buttons;
    [buttons[@"OK"] tap];

    NSString *resultsString = [self getInputsString];
    NSDictionary *resultsDictionary = [self parseJsonToDictionary:resultsString];
    NSDictionary *inputs = [self getInputsFromResultsDictionary:resultsDictionary];

    [self verifyInput:@"myColor" matchesExpectedValue:@"1" inInputSet:inputs];
    [self verifyInput:@"myColor2" matchesExpectedValue:@"2" inInputSet:inputs];
    [self verifyInput:@"myColor3" matchesExpectedValue:@"3" inInputSet:inputs];
    [self verifyInput:@"myColor4" matchesExpectedValue:@"1" inInputSet:inputs];
}

- (void)testCanGatherCorrectValuesFromChoiceset
{
    [self openCardForVersion:@"v1.3" forCardType:@"Elements" withCardName:@"Input.ChoiceSet.json"];

    XCUIElement *chatWindow = testApp.tables[@"ChatWindow"];
    [chatWindow.tables[@"myColor3"].staticTexts[@"myColor3, Blue"] tap];
    [chatWindow /*@START_MENU_TOKEN@*/.tables[@"myColor3"].staticTexts[@"myColor3, Red"] /*[[".cells.tables[@\"myColor3\"]",".cells[@\"Empty list, Red\"]",".staticTexts[@\"Red\"]",".staticTexts[@\"myColor3, Red\"]",".tables[@\"myColor3\"]"],[[[-1,4,1],[-1,0,1]],[[-1,3],[-1,2],[-1,1,2]],[[-1,3],[-1,2]]],[0,0]]@END_MENU_TOKEN@*/ tap];

    [chatWindow swipeUp];

    XCUIElementQuery *buttons = testApp.buttons;
    [buttons[@"OK"] tap];

    NSString *resultsString = [self getInputsString];
    NSDictionary *resultsDictionary = [self parseJsonToDictionary:resultsString];
    NSDictionary *inputs = [self getInputsFromResultsDictionary:resultsDictionary];

    [self verifyInput:@"myColor" matchesExpectedValue:@"1" inInputSet:inputs];
    [self verifyInput:@"myColor2" matchesExpectedValue:@"1" inInputSet:inputs];
    [self verifyInput:@"myColor3" matchesExpectedValue:@"" inInputSet:inputs];
    [self verifyInput:@"myColor4" matchesExpectedValue:@"1" inInputSet:inputs];
}

- (void)testHexColorCodeConversion
{
    const std::string testHexColorCode1 = "#FFa", testHexColorCode2 = "#FF123456",
                      testHexColorCode3 = "#FF1234G6", testHexColorCode4 = "#FF12345G",
                      testHexColorCode5 = "#FF1234  ", testHexColorCode6 = "#FF    56",
                      testHexColorCode7 = "   #FF123", testHexColorCode8 = "# FF12345",
                      testHexColorCode9 = "#  FF1234";
    UIColor *color1 = [ACOHostConfig convertHexColorCodeToUIColor:testHexColorCode1];
    XCTAssertTrue(CGColorEqualToColor(color1.CGColor, UIColor.clearColor.CGColor));

    UIColor *color2 = [ACOHostConfig convertHexColorCodeToUIColor:testHexColorCode2];
    XCTAssertTrue(!CGColorEqualToColor(color2.CGColor, UIColor.clearColor.CGColor));

    UIColor *color3 = [ACOHostConfig convertHexColorCodeToUIColor:testHexColorCode3];
    XCTAssertTrue(CGColorEqualToColor(color3.CGColor, UIColor.clearColor.CGColor));

    UIColor *color4 = [ACOHostConfig convertHexColorCodeToUIColor:testHexColorCode4];
    XCTAssertTrue(CGColorEqualToColor(color4.CGColor, UIColor.clearColor.CGColor));

    UIColor *color5 = [ACOHostConfig convertHexColorCodeToUIColor:testHexColorCode5];
    XCTAssertTrue(CGColorEqualToColor(color5.CGColor, UIColor.clearColor.CGColor));

    UIColor *color6 = [ACOHostConfig convertHexColorCodeToUIColor:testHexColorCode6];
    XCTAssertTrue(CGColorEqualToColor(color6.CGColor, UIColor.clearColor.CGColor));

    UIColor *color7 = [ACOHostConfig convertHexColorCodeToUIColor:testHexColorCode7];
    XCTAssertTrue(CGColorEqualToColor(color7.CGColor, UIColor.clearColor.CGColor));

    UIColor *color8 = [ACOHostConfig convertHexColorCodeToUIColor:testHexColorCode8];
    XCTAssertTrue(CGColorEqualToColor(color8.CGColor, UIColor.clearColor.CGColor));

    UIColor *color9 = [ACOHostConfig convertHexColorCodeToUIColor:testHexColorCode9];
    XCTAssertTrue(CGColorEqualToColor(color9.CGColor, UIColor.clearColor.CGColor));
}

- (void)testDynamicTypeaheadSearchFromChoiceset
{
    NSString *payload = [NSString stringWithContentsOfFile:@"../samples/v1.6/Tests/Input.ChoiceSet.Static&DynamicTypeahead.json" encoding:NSUTF8StringEncoding error:nil];
    ACOAdaptiveCardParseResult *cardParseResult = [ACOAdaptiveCard fromJson:payload];
    if (!cardParseResult.isValid) {
        return;
    }

    XCUICoordinate *startPoint = [testApp.buttons[@"v1.3"] coordinateWithNormalizedOffset:CGVectorMake(0, 0)]; // center of the element
    XCUICoordinate *finishPoint = [startPoint coordinateWithOffset:CGVectorMake(-1000, 0)];                    // adjust the x-offset to move left
    [startPoint pressForDuration:0 thenDragToCoordinate:finishPoint];
    [self openCardForVersion:@"v1.6" forCardType:@"Tests" withCardName:@"Input.ChoiceSet.DynamicTypeahead.json"];
    XCUIElement *chosenpackageButton = testApp.tables[@"ChatWindow"].buttons[@"chosenPackage"];
    [chosenpackageButton tap];

    // back button test
    XCUIElement *backButton = testApp.buttons[@"Back"];
    [backButton tap];

    [chosenpackageButton tap];

    XCUIElement *searchBarChosenpackageTable = testApp.otherElements[@"searchBar, chosenPackage"];

    [searchBarChosenpackageTable typeText:@"microsoft"];
    [NSThread sleepForTimeInterval:0.2];
    XCUIElement *listviewChosenpackageTable = testApp.tables[@"listView, chosenPackage"];
    [listviewChosenpackageTable.staticTexts[@"Microsoft.Extensions.Hosting.Abstractions"] tap];
    // Execute a drag from the 4th element to the 2nd element

    XCUIElementQuery *buttons = testApp.buttons;
    [buttons[@"OK"] tap];

    NSString *resultsString = [self getInputsString];
    NSDictionary *resultsDictionary = [self parseJsonToDictionary:resultsString];
    NSDictionary *inputs = [self getInputsFromResultsDictionary:resultsDictionary];
    [self verifyInput:@"chosenPackage" matchesExpectedValue:@"Hosting and startup abstractions for applications." inInputSet:inputs];
}

- (void)testStaticDynamicTypeaheadSearchFromChoiceset
{
    NSString *payload = [NSString stringWithContentsOfFile:@"../samples/v1.6/Tests/Input.ChoiceSet.Static&DynamicTypeahead.json" encoding:NSUTF8StringEncoding error:nil];
    ACOAdaptiveCardParseResult *cardParseResult = [ACOAdaptiveCard fromJson:payload];

    if (!cardParseResult.isValid) {
        return;
    }

    XCUICoordinate *startPoint = [testApp.buttons[@"v1.3"] coordinateWithNormalizedOffset:CGVectorMake(0, 0)]; // center of the element
    XCUICoordinate *finishPoint = [startPoint coordinateWithOffset:CGVectorMake(-1000, 0)];                    // adjust the x-offset to move left
    [startPoint pressForDuration:0 thenDragToCoordinate:finishPoint];
    [self openCardForVersion:@"v1.6" forCardType:@"Tests" withCardName:@"Input.ChoiceSet.Static&DynamicTypeahead.json"];
    XCUIElement *choicesetPackageButton = testApp.tables[@"ChatWindow"].buttons[@"choiceset1"];
    [choicesetPackageButton tap];

    // back button test
    XCUIElement *backButton = testApp.buttons[@"Back"];
    [backButton tap];

    [choicesetPackageButton tap];

    // select static choice
    XCUIElement *listviewChoicesetPackageTable = testApp.tables[@"listView, choiceset1"];
    [listviewChoicesetPackageTable.staticTexts[@"Ms.IdentityModel.static"] tap];

    // press OK button
    XCUIElementQuery *buttons = testApp.buttons;
    [buttons[@"Submit"] tap];

    NSString *resultsString = [self getInputsString];
    NSDictionary *resultsDictionary = [self parseJsonToDictionary:resultsString];
    NSDictionary *inputs = [self getInputsFromResultsDictionary:resultsDictionary];
    [self verifyInput:@"choiceset1" matchesExpectedValue:@"4" inInputSet:inputs];

    // select dynamic choice
    choicesetPackageButton = testApp.tables[@"ChatWindow"].buttons[@"choiceset1"];
    [choicesetPackageButton tap];
    XCUIElement *searchBarChoicesetPackageTable = testApp.otherElements[@"searchBar, choiceset1"];
    [searchBarChoicesetPackageTable typeText:@"Microsoft.Extensions.Hosting.Abstractions"];
    [NSThread sleepForTimeInterval:0.2];
    listviewChoicesetPackageTable = testApp.tables[@"listView, choiceset1"];
    [listviewChoicesetPackageTable.staticTexts[@"Microsoft.Extensions.Hosting.Abstractions"] tap];

    buttons = testApp.buttons;
    [buttons[@"Submit"] tap];

    resultsString = [self getInputsString];
    resultsDictionary = [self parseJsonToDictionary:resultsString];
    inputs = [self getInputsFromResultsDictionary:resultsDictionary];
    [self verifyInput:@"choiceset1" matchesExpectedValue:@"Hosting and startup abstractions for applications." inInputSet:inputs];
}

- (void) testPopoverInput1SuccessfulSubmission
{
    [self openCardForVersion:@"v1.5" forCardType:@"Elements" withCardName:@"Action.Popover.json"];
    
    // Type in "Outside Popover Input Required *"
    XCUIElement *outsideRequired = [testApp.textFields elementMatchingPredicate:[NSPredicate predicateWithFormat:@"identifier == %@", @"outsidePopover1"]];
    XCTAssertTrue(outsideRequired.exists);
    [outsideRequired tap];
    [NSThread sleepForTimeInterval:0.5]; // Wait for keyboard focus
    [outsideRequired typeText:@"text outside popover required"];
    
    // Type in "Outside Popover Input"
    XCUIElement *outsideInput = [testApp.textFields elementMatchingPredicate:[NSPredicate predicateWithFormat:@"identifier == %@", @"outsidePopover2"]];
    XCTAssertTrue(outsideInput.exists);
    [outsideInput tap];
    [NSThread sleepForTimeInterval:0.5]; // Wait for keyboard focus
    [outsideInput typeText:@"text outside popover Input"];
    
    // Dismiss the keyboard
    XCUIElement *returnKey = testApp.keyboards.buttons[@"return"];
    if (returnKey.exists && returnKey.isHittable) {
        [returnKey tap];
    }
    
    // Scroll to and tap the "Add Name Popover" button
    XCUIElement *popoverButton = [testApp.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", @"Add Name Popover"]];
    XCTAssertTrue(popoverButton.exists);
    
    int maxScrolls = 5;
    int scrolls = 0;
    while (!popoverButton.hittable && scrolls < maxScrolls) {
        [testApp swipeUp];
        sleep(1);
        scrolls++;
    }
    XCTAssertTrue(popoverButton.hittable, @"Popover button should be hittable after scrolling");
    [popoverButton tap];
    
    // Type in the popover input
    XCUIElement *textField = [testApp.textFields elementMatchingPredicate:[NSPredicate predicateWithFormat:@"identifier == %@", @"inputInPopover1"]];
    XCTAssertTrue(textField.exists, @"Popover text field should exist after tapping and swiping if needed");
    [self checkAndTap:textField];
    [textField typeText:@"Input inside popover\n"];
    
    // Click on overflow button
    XCUIElement *overflowButton = [testApp.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", @"..."]];
    XCTAssertTrue(overflowButton.exists);
    [overflowButton tap];
    
    // Click on submit in the alert (popover/bottom sheet)
    XCUIElement *alert = testApp.alerts.element;
    XCUIElement *submitButton = [alert.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", @"Submit"]];
    XCTAssertTrue(submitButton.exists && submitButton.isHittable, @"Submit button in alert should exist and be hittable");
    [submitButton tap];
    
    // Verify all inputs
    NSString *resultsString = [self getInputsString];
    NSDictionary *resultsDictionary = [self parseJsonToDictionary:resultsString];
    NSDictionary *inputs = [self getInputsFromResultsDictionary:resultsDictionary];
    [self verifyInput:@"outsidePopover1" matchesExpectedValue:@"text outside popover required" inInputSet:inputs];
    [self verifyInput:@"outsidePopover2" matchesExpectedValue:@"text outside popover Input" inInputSet:inputs];
    [self verifyInput:@"inputInPopover1" matchesExpectedValue:@"Input inside popover" inInputSet:inputs];
    
    // After clicking submit and before/after parsing the results:
    XCUIElement *resultsText = [testApp.staticTexts elementMatchingType:XCUIElementTypeAny identifier:@"SubmitActionRetrievedResults"];
    XCTAssertTrue(resultsText.exists, @"SubmitActionRetrievedResults static text should exist");
    
    // Build the expected label string (make sure to match the actual output format)
    // The actual label ends with an extra newline, so match that
    NSString *expectedLabel = @"{ \t\"inputs\":{   \"outsidePopover2\" : \"text outside popover Input\",   \"inputInPopover1\" : \"Input inside popover\",   \"outsidePopover1\" : \"text outside popover required\" }, \"data\" : null\n}\n";
    
    NSCharacterSet *whitespaceAndNewline = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    
    NSString *cleanExpected = [[expectedLabel componentsSeparatedByCharactersInSet:whitespaceAndNewline] componentsJoinedByString:@""];
    NSString *cleanActual = [[resultsText.label componentsSeparatedByCharactersInSet:whitespaceAndNewline] componentsJoinedByString:@""];
    
    XCTAssertEqualObjects(cleanActual, cleanExpected, @"SubmitActionRetrievedResults label should match expected JSON ignoring whitespace");
}

- (void) testPopoverInput1Submission
{
    [self openCardForVersion:@"v1.5" forCardType:@"Elements" withCardName:@"Action.Popover.json"];
    
    // Scroll to and tap the "Add Name Popover" button
    XCUIElement *popoverButton = [testApp.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", @"Add Name Popover"]];
    XCTAssertTrue(popoverButton.exists);
    
    int maxScrolls = 5;
    int scrolls = 0;
    while (!popoverButton.hittable && scrolls < maxScrolls) {
        [testApp swipeUp];
        sleep(1);
        scrolls++;
    }
    XCTAssertTrue(popoverButton.hittable, @"Popover button should be hittable after scrolling");
    [popoverButton tap];
    
    // Type in the popover input
    XCUIElement *textField = [testApp.textFields elementMatchingPredicate:[NSPredicate predicateWithFormat:@"identifier == %@", @"inputInPopover1"]];
    XCTAssertTrue(textField.exists, @"Popover text field should exist after tapping and swiping if needed");
    [self checkAndTap:textField];
    [textField typeText:@"Input inside popover\n"];
    
    // Click on overflow button
    XCUIElement *overflowButton = [testApp.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", @"..."]];
    XCTAssertTrue(overflowButton.exists);
    [overflowButton tap];
    
    // Click on submit in the alert (popover/bottom sheet)
    XCUIElement *alert = testApp.alerts.element;
    XCUIElement *submitButton = [alert.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", @"Submit"]];
    XCTAssertTrue(submitButton.exists && submitButton.isHittable, @"Submit button in alert should exist and be hittable");
    [submitButton tap];
    
    // Verify all inputs
    NSString *resultsString = [self getInputsString];
    NSDictionary *resultsDictionary = [self parseJsonToDictionary:resultsString];
    NSDictionary *inputs = [self getInputsFromResultsDictionary:resultsDictionary];
    XCTAssertNil(inputs);
}

- (void) testPopoverRatingSuccessfulSubmission
{
    [self openCardForVersion:@"v1.5" forCardType:@"Elements" withCardName:@"Action.Popover.json"];
    // Type in "Outside Popover Input Required *"
    XCUIElement *outsideRequired = [testApp.textFields elementMatchingPredicate:[NSPredicate predicateWithFormat:@"identifier == %@", @"outsidePopover1"]];
    XCTAssertTrue(outsideRequired.exists);
    [outsideRequired tap];
    [NSThread sleepForTimeInterval:0.5]; // Wait for keyboard focus
    [outsideRequired typeText:@"text outside popover required"];
    
    // Type in "Outside Popover Input"
    XCUIElement *outsideInput = [testApp.textFields elementMatchingPredicate:[NSPredicate predicateWithFormat:@"identifier == %@", @"outsidePopover2"]];
    XCTAssertTrue(outsideInput.exists);
    [outsideInput tap];
    [NSThread sleepForTimeInterval:0.5]; // Wait for keyboard focus
    [outsideInput typeText:@"text outside popover Input"];
    
    // Dismiss the keyboard
    XCUIElement *returnKey = testApp.keyboards.buttons[@"return"];
    if (returnKey.exists && returnKey.isHittable) {
        [returnKey tap];
    }
    XCUIElement *popoverButton = [testApp.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", @"Select rating Popover"]];
    XCTAssertTrue(popoverButton.exists, @"Popover Button - Select rating popover should exist after tapping and swiping if needed");
    [self checkAndTap:popoverButton];

    // Adjust this to select a rating (e.g., tap the 4th star for rating=4)
    // Tap the 4th star for rating=4
    XCUIElement *fourthStar = [testApp.images elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", @"Rate 4 Star"]];
    XCTAssertTrue(fourthStar.exists && fourthStar.isHittable, @"The 4th star should exist and be hittable");
    [fourthStar tap];

    // Click on submit in the alert (popover/bottom sheet)
    XCUIElement *alert = testApp.alerts.element;
    XCUIElement *submitButton = [alert.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", @"Submit"]];
    
    if (!submitButton.exists)
    {
        XCUIElementQuery *submitButtons = [testApp.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", @"Submit"]];
        submitButton = nil;
        for (NSUInteger i = 0; i < submitButtons.count; i++) {
            XCUIElement *button = [submitButtons elementBoundByIndex:i];
            if (button.exists && button.isHittable) {
                submitButton = button;
                break;
            }
        }
    }
    XCTAssertTrue(submitButton.exists && submitButton.isHittable, @"Submit button in alert should exist and be hittable");
    [submitButton tap];

    // Verify all inputs
    NSString *resultsString = [self getInputsString];
    NSDictionary *resultsDictionary = [self parseJsonToDictionary:resultsString];
    NSDictionary *inputs = [self getInputsFromResultsDictionary:resultsDictionary];
    [self verifyNumberInput:@"rating1" matchesExpectedValue:@"4" inInputSet:inputs];

    // After clicking submit and before/after parsing the results:
    XCUIElement *resultsText = [testApp.staticTexts elementMatchingType:XCUIElementTypeAny identifier:@"SubmitActionRetrievedResults"];
    XCTAssertTrue(resultsText.exists, @"SubmitActionRetrievedResults static text should exist");

    NSString *expectedLabel = @"{ \
    \"inputs\":{ \
    \"outsidePopover2\":\"textoutsidepopoverInput\", \
    \"rating1\":4, \
    \"outsidePopover1\":\"textoutsidepopoverrequired\" \
    }, \
    \"data\":null \
    }";
    
    NSCharacterSet *whitespaceAndNewline = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *cleanExpected = [[expectedLabel componentsSeparatedByCharactersInSet:whitespaceAndNewline] componentsJoinedByString:@""];
    NSString *cleanActual = [[resultsText.label componentsSeparatedByCharactersInSet:whitespaceAndNewline] componentsJoinedByString:@""];
    XCTAssertEqualObjects(cleanActual, cleanExpected, @"SubmitActionRetrievedResults label should match expected JSON ignoring whitespace");
}

- (void) testPopoverRatingSubmission
{
    [self openCardForVersion:@"v1.5" forCardType:@"Elements" withCardName:@"Action.Popover.json"];
    XCUIElement *popoverButton = [testApp.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", @"Select rating Popover"]];
    XCTAssertTrue(popoverButton.exists, @"Popover button - Select rating popover should exist after tapping and swiping if needed");
    [self checkAndTap:popoverButton];

    // Adjust this to select a rating (e.g., tap the 4th star for rating=4)
    // Tap the 4th star for rating=4
    XCUIElement *fourthStar = [testApp.images elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", @"Rate 4 Star"]];
    XCTAssertTrue(fourthStar.exists && fourthStar.isHittable, @"The 4th star should exist and be hittable");
    [fourthStar tap];

    // Click on submit in the alert (popover/bottom sheet)
    XCUIElement *alert = testApp.alerts.element;
    XCUIElement *submitButton = [alert.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", @"Submit"]];
    
    if (!submitButton.exists)
    {
        XCUIElementQuery *submitButtons = [testApp.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", @"Submit"]];
        submitButton = nil;
        for (NSUInteger i = 0; i < submitButtons.count; i++) {
            XCUIElement *button = [submitButtons elementBoundByIndex:i];
            if (button.exists && button.isHittable) {
                submitButton = button;
                break;
            }
        }
    }
    XCTAssertTrue(submitButton.exists && submitButton.isHittable, @"Submit button in alert should exist and be hittable");
    [submitButton tap];

    // Verify all inputs
    NSString *resultsString = [self getInputsString];
    NSDictionary *resultsDictionary = [self parseJsonToDictionary:resultsString];
    NSDictionary *inputs = [self getInputsFromResultsDictionary:resultsDictionary];
    XCTAssertNil(inputs);
}

- (void) testPopoverInput2SuccessfulSubmission
{
    [self openCardForVersion:@"v1.5" forCardType:@"Elements" withCardName:@"Action.Popover.json"];
    
    // Type in "Outside Popover Input Required *"
    XCUIElement *outsideRequired = [testApp.textFields elementMatchingPredicate:[NSPredicate predicateWithFormat:@"identifier == %@", @"outsidePopover1"]];
    XCTAssertTrue(outsideRequired.exists);
    [outsideRequired tap];
    [NSThread sleepForTimeInterval:0.5]; // Wait for keyboard focus
    [outsideRequired typeText:@"text outside popover required"];
    
    // Type in "Outside Popover Input"
    XCUIElement *outsideInput = [testApp.textFields elementMatchingPredicate:[NSPredicate predicateWithFormat:@"identifier == %@", @"outsidePopover2"]];
    XCTAssertTrue(outsideInput.exists);
    [outsideInput tap];
    [NSThread sleepForTimeInterval:0.5]; // Wait for keyboard focus
    [outsideInput typeText:@"text outside popover Input"];
    
    // Dismiss the keyboard
    XCUIElement *returnKey = testApp.keyboards.buttons[@"return"];
    if (returnKey.exists && returnKey.isHittable) {
        [returnKey tap];
    }
    
    // Scroll to and tap the "Add Name Popover" button
    XCUIElement *popoverButton = [testApp.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", @"Add Number Popover"]];
    XCTAssertTrue(popoverButton.exists);
    
    int maxScrolls = 5;
    int scrolls = 0;
    while (!popoverButton.hittable && scrolls < maxScrolls) {
        [testApp swipeUp];
        sleep(1);
        scrolls++;
    }
    XCTAssertTrue(popoverButton.hittable, @"Popover button should be hittable after scrolling");
    [popoverButton tap];
    
    // Type in the popover input
    XCUIElement *textField = [testApp.textFields elementMatchingPredicate:[NSPredicate predicateWithFormat:@"identifier == %@", @"inputInPopover2"]];
    XCTAssertTrue(textField.exists, @"Popover text field should exist after tapping and swiping if needed");
    [self checkAndTap:textField];
    [textField typeText:@"1234\n"];
    
    // Click on overflow button
    XCUIElement *overflowButton = [testApp.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", @"..."]];
    XCTAssertTrue(overflowButton.exists);
    [overflowButton tap];
    
    // Click on submit in the alert (popover/bottom sheet)
    XCUIElement *alert = testApp.alerts.element;
    XCUIElement *submitButton = [alert.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", @"Submit"]];
    XCTAssertTrue(submitButton.exists && submitButton.isHittable, @"Submit button in alert should exist and be hittable");
    [submitButton tap];
    
    // Verify all inputs
    NSString *resultsString = [self getInputsString];
    NSDictionary *resultsDictionary = [self parseJsonToDictionary:resultsString];
    NSDictionary *inputs = [self getInputsFromResultsDictionary:resultsDictionary];
    [self verifyInput:@"outsidePopover1" matchesExpectedValue:@"text outside popover required" inInputSet:inputs];
    [self verifyInput:@"outsidePopover2" matchesExpectedValue:@"text outside popover Input" inInputSet:inputs];
    [self verifyNumberInput:@"inputInPopover2" matchesExpectedValue:@"1234" inInputSet:inputs];
    
    // After clicking submit and before/after parsing the results:
    XCUIElement *resultsText = [testApp.staticTexts elementMatchingType:XCUIElementTypeAny identifier:@"SubmitActionRetrievedResults"];
    XCTAssertTrue(resultsText.exists, @"SubmitActionRetrievedResults static text should exist");
    
    // Build the expected label string (make sure to match the actual output format)
    // The actual label ends with an extra newline, so match that
    NSString *expectedLabel = @"{ \
    \"inputs\":{ \
    \"outsidePopover2\":\"textoutsidepopoverInput\", \
    \"inputInPopover2\":\"1234\", \
    \"outsidePopover1\":\"textoutsidepopoverrequired\" \
    }, \
    \"data\":null \
    }";
    
    NSCharacterSet *whitespaceAndNewline = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    
    NSString *cleanExpected = [[expectedLabel componentsSeparatedByCharactersInSet:whitespaceAndNewline] componentsJoinedByString:@""];
    NSString *cleanActual = [[resultsText.label componentsSeparatedByCharactersInSet:whitespaceAndNewline] componentsJoinedByString:@""];
    
    XCTAssertEqualObjects(cleanActual, cleanExpected, @"SubmitActionRetrievedResults label should match expected JSON ignoring whitespace");
}

- (void) testPopoverInput2Submission
{
    [self openCardForVersion:@"v1.5" forCardType:@"Elements" withCardName:@"Action.Popover.json"];
    
    // Scroll to and tap the "Add Name Popover" button
    XCUIElement *popoverButton = [testApp.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", @"Add Number Popover"]];
    XCTAssertTrue(popoverButton.exists);
    
    int maxScrolls = 5;
    int scrolls = 0;
    while (!popoverButton.hittable && scrolls < maxScrolls) {
        [testApp swipeUp];
        sleep(1);
        scrolls++;
    }
    XCTAssertTrue(popoverButton.hittable, @"Popover button should be hittable after scrolling");
    [popoverButton tap];
    
    // Type in the popover input
    XCUIElement *textField = [testApp.textFields elementMatchingPredicate:[NSPredicate predicateWithFormat:@"identifier == %@", @"inputInPopover2"]];
    XCTAssertTrue(textField.exists, @"Popover text field should exist after tapping and swiping if needed");
    [self checkAndTap:textField];
    [textField typeText:@"1234\n"];
    
    // Click on overflow button
    XCUIElement *overflowButton = [testApp.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", @"..."]];
    XCTAssertTrue(overflowButton.exists);
    [overflowButton tap];
    
    // Click on submit in the alert (popover/bottom sheet)
    XCUIElement *alert = testApp.alerts.element;
    XCUIElement *submitButton = [alert.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", @"Submit"]];
    XCTAssertTrue(submitButton.exists && submitButton.isHittable, @"Submit button in alert should exist and be hittable");
    [submitButton tap];
    
    // Verify all inputs
    NSString *resultsString = [self getInputsString];
    NSDictionary *resultsDictionary = [self parseJsonToDictionary:resultsString];
    NSDictionary *inputs = [self getInputsFromResultsDictionary:resultsDictionary];
    XCTAssertNil(inputs);
}

- (void) testPopoverRendering
{
    [self openCardForVersion:@"v1.5" forCardType:@"Elements" withCardName:@"Action.Popover.json"];
    XCUIElement *popoverButton = [testApp.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", @"Less Content Popover"]];
    XCTAssertTrue(popoverButton.exists);
    [popoverButton tap];

    XCUIElement *lessContentTextView = [testApp.textViews elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", @"Less Content"]];
    XCTAssertTrue(lessContentTextView.exists, @"'Less Content' TextView should exist");
    [self dismissPopoverBottomSheet];
    XCUIElement *containerButton = [testApp.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", @"This Container is clickable and will show a popover"]];
    XCTAssertTrue([containerButton waitForExistenceWithTimeout:kACRPopoverTimeout] && containerButton.isHittable, @"'This Container is clickable and will show a popover' button should exist and be hittable");
    [containerButton tap];
    XCUIElement *popoverTextView = [testApp.textViews elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", @"This is a popover"]];
    XCTAssertTrue(popoverTextView.exists, @"'This is a popover' TextView should exist");
    [self dismissPopoverBottomSheet];
    // Matched with CONTAINS rather than == on purpose. The composed label currently carries
    // a leading ", " because configureForAccessibilityLabel joins an empty title component
    // (UtiliOS.mm: `if (action.title)` is a nil-check, and an absent title arrives as @"").
    // Asserting the exact string would pin the test to that artifact and break the moment
    // it is fixed; matching on the tooltip text is correct either way.
    XCUIElement *popoverIcon = [testApp.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS[c] %@", @"Click me to show a popover"]];
    XCTAssertTrue([popoverIcon waitForExistenceWithTimeout:kACRPopoverTimeout] && popoverIcon.isHittable, @"Button 'Click me to show a popover' should exist and be hittable");
    [popoverIcon tap];
    popoverTextView = [testApp.textViews elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", @"This Popover is made with Adaptive Card elements, it supports actions and is fully accessible."]];
    XCTAssertTrue(popoverTextView.exists, @"The icon popover TextView with the expected label should exist");
    [self dismissPopoverBottomSheet];
    
    XCUIElement *progressBarButton = [testApp.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", @"Progress Bar"]];
    XCTAssertTrue(progressBarButton.exists, @"'Progress Bar' button should exist and be hittable");
    [self checkAndTap:progressBarButton];
    NSArray<NSString *> *labels = @[
        @"Progress in Accent",
        @"Progress in Attention",
        @"Progress in Good",
        @"Progress in Warning",
        @"No Progress"
    ];

    for (NSString *label in labels) {
        XCUIElement *textView = [testApp.textViews elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", label]];
        XCTAssertTrue(textView.exists, "%s", [[NSString stringWithFormat:@"TextView with label '%@' should exist", label] UTF8String]);
    }
    [self dismissPopoverBottomSheet];
}

- (void) dismissPopoverBottomSheet
{
    XCUIElement *dismissButton = [testApp.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", @"Dismiss"]];
    XCTAssertTrue([dismissButton waitForExistenceWithTimeout:kACRPopoverTimeout] && dismissButton.isHittable, @"'Dismiss' button should exist and be hittable");
    [dismissButton tap];

    // The bottom sheet dismisses with an animation. Returning as soon as the tap is
    // delivered makes every caller race that animation: the element underneath already
    // exists, but is still covered by the outgoing sheet, so isHittable reports NO.
    // Wait for the sheet to actually leave the hierarchy before handing control back.
    [self expectationForPredicate:[NSPredicate predicateWithFormat:@"exists == NO"]
                        evaluatedWithObject:dismissButton
                                    handler:nil];
    [self waitForExpectationsWithTimeout:kACRPopoverTimeout handler:nil];
}

- (void) checkAndTap:(XCUIElement *)element
{
    int maxSwipes = 5, swipes = 0;
    while (!element.isHittable && swipes < maxSwipes)
    {
        [testApp swipeUp];
        swipes++;
    }
    [element tap];
}


#pragma mark - Accessibility-Driven UI Automation

/// Discover all accessible elements in VoiceOver reading order.
/// Returns an array of dictionaries with label, value, role, frame, identifier.
/// This is the iOS equivalent of Android's AccessibilityNodeInfo traversal.
- (NSArray *)discoverAccessibleElements
{
    NSMutableArray *elements = [NSMutableArray array];
    
    // Query each VoiceOver-relevant element type in order
    // Link, cell, checkBox and radioButton were absent here, which made whole classes
    // of fix unmeasurable: anything whose purpose is to surface a link range or a choice
    // cell as its own accessibility element produced a byte-identical dump, and that read
    // as "the fix does nothing" when the scanner simply never asked for those types.
    XCUIElementType scanTypes[] = {
        XCUIElementTypeButton, XCUIElementTypeStaticText,
        XCUIElementTypeTextField, XCUIElementTypeTextView,
        XCUIElementTypeImage, XCUIElementTypeSwitch, XCUIElementTypeSlider,
        XCUIElementTypeLink, XCUIElementTypeCell,
        XCUIElementTypeCheckBox, XCUIElementTypeRadioButton,
    };
    NSString *roleNames[] = {@"button", @"text", @"textField", @"textView", @"image", @"switch", @"slider",
                             @"link", @"cell", @"checkBox", @"radioButton"};

    // The visualizer is a split view: the master sample list (46+ "*.json" rows)
    // stays visible alongside the rendered-card pane (the "ChatWindow" table).
    // Scanning the whole app conflates both, drowning card content in list rows.
    // Scope the scan to the ChatWindow when it exists so element dumps reflect the
    // card under test; fall back to the whole app otherwise.
    XCUIElement *chatWindow = testApp.tables[@"ChatWindow"];
    id scanRoot = ([chatWindow exists]) ? (id)chatWindow : (id)testApp;

    const int scanTypeCount = (int)(sizeof(scanTypes) / sizeof(scanTypes[0]));
    for (int t = 0; t < scanTypeCount; t++) {
        XCUIElementQuery *q = [scanRoot descendantsMatchingType:scanTypes[t]];
        NSUInteger count = q.count;
        for (NSUInteger i = 0; i < count && i < 50; i++) {
            @try {
                XCUIElement *elem = [q elementBoundByIndex:i];
                if (!elem.exists) continue;
                NSString *label = elem.label ?: @"";
                if (label.length == 0) continue;
                NSString *value = elem.value ? [NSString stringWithFormat:@"%@", elem.value] : @"";
                NSString *identifier = elem.identifier ?: @"";
                CGRect frame = elem.frame;
                if (frame.size.width < 5 || frame.size.height < 5) continue;
                if (frame.size.width > 390 && frame.size.height > 800) continue;
                
                [elements addObject:@{
                    @"label": label,
                    @"value": value,
                    @"role": roleNames[t],
                    @"identifier": identifier,
                    @"frame": @{@"x": @(frame.origin.x), @"y": @(frame.origin.y),
                                @"width": @(frame.size.width), @"height": @(frame.size.height)},
                    @"isEnabled": @(elem.isEnabled),
                    @"isSelected": @(elem.isSelected),
                    @"isHittable": @(elem.isHittable),
                }];
            } @catch (NSException *e) { continue; }
        }
    }
    
    // Sort by position (reading order: top-to-bottom, left-to-right)
    [elements sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        CGFloat ay = [a[@"frame"][@"y"] floatValue];
        CGFloat by = [b[@"frame"][@"y"] floatValue];
        if (fabs(ay - by) > 10) return ay < by ? NSOrderedAscending : NSOrderedDescending;
        CGFloat ax = [a[@"frame"][@"x"] floatValue];
        CGFloat bx = [b[@"frame"][@"x"] floatValue];
        return ax < bx ? NSOrderedAscending : NSOrderedDescending;
    }];
    
    return elements;
}

/// Find and tap an element by its accessibility label. Returns YES if found.
/// This is the core of a11y-driven navigation — find by label, not coordinates.
/// Scroll a known-but-off-screen element into view by swiping up on the
/// first scroll/table container, up to a few times, until it is hittable.
- (BOOL)scrollElementIntoView:(XCUIElement *)element
{
    if (![element exists]) { return NO; }
    if ([element isHittable]) { return YES; }
    // The sample list is the SECOND table (index 1) in the split view, matching
    // openCardForVersion. Fall back to table 0 / first scroll view / the app.
    XCUIElement *scroller = [[testApp tables] elementBoundByIndex:1];
    if (![scroller exists]) { scroller = [[testApp tables] elementBoundByIndex:0]; }
    if (![scroller exists]) { scroller = [[testApp scrollViews] elementBoundByIndex:0]; }
    if (![scroller exists]) { scroller = testApp; }
    // The sample lists run to 60+ rows and every row reports the SAME accessibility
    // frame, so `isHittable` only becomes true once the row physically occupies that
    // rect. Eight swipes reached cards mid-list (FluentIcon.RTL succeeded) but not ones
    // lower down: CompoundButtonSample, FoodOrder and
    // ColumnSet.Input.ChoiceSet.VerticalStretch all exhausted the budget and failed
    // navigation, so their scenarios produced no evidence at all.
    // Do NOT add a "list stopped moving" early exit keyed on the first visible
    // staticText: that row is a static header, so it never changes and the loop bails
    // after two swipes. Run 31523879793 tried it and regressed RatingInput from pass to
    // fail and lost FoodOrder again, which run 31520125257 had captured with the plain
    // budget below. The budget is bounded and the job timeout (70m) accommodates it.
    for (int i = 0; i < 30 && [element exists] && ![element isHittable]; i++) {
        [scroller swipeUp];
    }
    if ([element exists] && [element isHittable]) {
        return YES;
    }
    // The row may sit above the starting scroll position; sweep back the other way.
    for (int i = 0; i < 30 && [element exists] && ![element isHittable]; i++) {
        [scroller swipeDown];
    }
    return [element exists] && [element isHittable];
}

- (BOOL)tapByAccessibilityLabel:(NSString *)label
{
    // Try buttons first (most common interactive element)
    XCUIElement *button = testApp.buttons[label];
    if ([button exists] && [button isHittable]) {
        [button tap];
        NSLog(@"A11Y_NAV: tapped button '%@'", label);
        return YES;
    }
    
    // Try static texts (table cells, list items)
    XCUIElement *text = testApp.staticTexts[label];
    if ([text exists] && [text isHittable]) {
        [text tap];
        NSLog(@"A11Y_NAV: tapped text '%@'", label);
        return YES;
    }
    
    // Try any element type
    NSPredicate *pred = [NSPredicate predicateWithFormat:@"label == %@", label];
    XCUIElement *any = [[testApp descendantsMatchingType:XCUIElementTypeAny] elementMatchingPredicate:pred];
    if ([any exists] && [any isHittable]) {
        [any tap];
        NSLog(@"A11Y_NAV: tapped element '%@'", label);
        return YES;
    }
    
    // Off-screen in a long list: scroll the matching element into view, then tap.
    NSPredicate *labelPred = [NSPredicate predicateWithFormat:@"label == %@", label];
    XCUIElement *offscreen = [[testApp descendantsMatchingType:XCUIElementTypeAny]
                              elementMatchingPredicate:labelPred];
    if ([offscreen exists] && [self scrollElementIntoView:offscreen]) {
        [offscreen tap];
        NSLog(@"A11Y_NAV: scrolled+tapped '%@'", label);
        return YES;
    }

    NSLog(@"A11Y_NAV: element '%@' not found or not hittable", label);
    return NO;
}

/// Navigate to a card by name using only accessibility navigation.
/// Discovers the menu structure and navigates using labels.
- (BOOL)navigateToCardByA11y:(NSString *)version type:(NSString *)type card:(NSString *)cardName
{
    // Step 1: Find and tap version button via a11y label
    if (![self tapByAccessibilityLabel:version]) {
        NSLog(@"A11Y_NAV: version '%@' not accessible", version);
        return NO;
    }
    [NSThread sleepForTimeInterval:0.5];
    
    // Step 2: Find and tap card type via a11y label
    if (![self tapByAccessibilityLabel:type]) {
        NSLog(@"A11Y_NAV: type '%@' not accessible", type);
        return NO;
    }
    [NSThread sleepForTimeInterval:0.5];
    
    // Step 3: Find and tap card name via a11y label
    if (![self tapByAccessibilityLabel:cardName]) {
        NSLog(@"A11Y_NAV: card '%@' not accessible", cardName);
        return NO;
    }
    [NSThread sleepForTimeInterval:1.5]; // Wait for card to render
    
    NSLog(@"A11Y_NAV: navigated to %@/%@/%@", version, type, cardName);
    return YES;
}

/// Save a11y state: element tree + screenshot to /tmp/a11y-xcui/
- (void)saveA11yState:(NSString *)name
{
    NSArray *elements = [self discoverAccessibleElements];
    
    // Write element JSON
    NSString *dir = @"/tmp/a11y-xcui";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:elements
                                                       options:NSJSONWritingPrettyPrinted error:nil];
    NSString *elemPath = [NSString stringWithFormat:@"%@/%@_elements.json", dir, name];
    [jsonData writeToFile:elemPath atomically:YES];
    
    // Screenshot
    XCUIScreenshot *screenshot = [XCUIScreen.mainScreen screenshot];
    NSString *shotPath = [NSString stringWithFormat:@"%@/%@.png", dir, name];
    [screenshot.PNGRepresentation writeToFile:shotPath atomically:YES];
    
    NSLog(@"A11Y_STATE: %@ -> %lu elements", name, (unsigned long)elements.count);
    
    // Log VoiceOver reading order
    for (NSUInteger i = 0; i < elements.count && i < 20; i++) {
        NSDictionary *e = elements[i];
        NSString *voiceoverReads = e[@"label"];
        if ([e[@"value"] length] > 0) {
            voiceoverReads = [NSString stringWithFormat:@"%@, %@", voiceoverReads, e[@"value"]];
        }
        NSLog(@"A11Y_VO: %lu. [%@] %@", (unsigned long)(i + 1), e[@"role"], voiceoverReads);
    }
}

#pragma mark - A11y Automation Test: Navigate Any Card

/// Accessibility-driven automation: navigate to a card, interact with
/// interactive elements (buttons, ShowCards), and capture a11y state at each step.
/// All navigation uses accessibility labels only — no coordinates, no view hierarchy.
- (void)testA11yAutomation_ActivityUpdate
{
    NSLog(@"A11Y_AUTO: === Starting ActivityUpdate a11y automation ===");
    
    // Navigate using a11y labels only
    BOOL navigated = [self navigateToCardByA11y:@"v1.5" type:@"Scenarios" card:@"ActivityUpdate.json"];
    XCTAssertTrue(navigated, @"Should navigate to ActivityUpdate via a11y labels");
    
    // Capture initial card state
    [self saveA11yState:@"auto_activity_initial"];
    
    // Discover all interactive elements on the rendered card
    NSArray *elements = [self discoverAccessibleElements];
    NSLog(@"A11Y_AUTO: Found %lu accessible elements on card", (unsigned long)elements.count);
    
    // Find all buttons (interactive elements VoiceOver can activate)
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSDictionary *e in elements) {
        if ([e[@"role"] isEqualToString:@"button"] && [e[@"isHittable"] boolValue]) {
            [buttons addObject:e];
        }
    }
    NSLog(@"A11Y_AUTO: %lu hittable buttons found", (unsigned long)buttons.count);
    
    // Try to find ShowCard buttons (Comment, Set due date) via a11y label
    BOOL foundComment = NO;
    for (NSDictionary *btn in buttons) {
        if ([btn[@"label"] isEqualToString:@"Comment"]) {
            foundComment = YES;
            NSLog(@"A11Y_AUTO: Found ShowCard button 'Comment' via a11y label");
            
            // Tap it to expand ShowCard
            [self tapByAccessibilityLabel:@"Comment"];
            [NSThread sleepForTimeInterval:1.5];
            
            // Capture expanded state
            [self saveA11yState:@"auto_activity_showcard_expanded"];
            
            // Verify new elements appeared (the ShowCard content)
            NSArray *expandedElements = [self discoverAccessibleElements];
            XCTAssertGreaterThan(expandedElements.count, elements.count,
                @"Expanded ShowCard should have more a11y elements than collapsed");
            NSLog(@"A11Y_AUTO: ShowCard expanded: %lu -> %lu elements",
                  (unsigned long)elements.count, (unsigned long)expandedElements.count);
            
            break;
        }
    }
    
    if (!foundComment) {
        NSLog(@"A11Y_AUTO: 'Comment' button not found — listing all button labels:");
        for (NSDictionary *btn in buttons) {
            NSLog(@"A11Y_AUTO:   button: '%@'", btn[@"label"]);
        }
    }
}

/// Accessibility-driven automation for ExpenseReport card.
/// Demonstrates navigating to a different card and finding ToggleVisibility.
- (void)testA11yAutomation_ExpenseReport
{
    NSLog(@"A11Y_AUTO: === Starting ExpenseReport a11y automation ===");
    
    // Navigate using a11y labels
    BOOL navigated = [self navigateToCardByA11y:@"v1.5" type:@"Scenarios" card:@"ExpenseReport.json"];
    XCTAssertTrue(navigated, @"Should navigate to ExpenseReport via a11y labels");
    
    // Capture card state
    [self saveA11yState:@"auto_expense_initial"];
    
    // Discover elements
    NSArray *elements = [self discoverAccessibleElements];
    NSLog(@"A11Y_AUTO: Found %lu accessible elements", (unsigned long)elements.count);
    
    // Find any button that might be a ShowCard (Reject, Approve)
    for (NSDictionary *e in elements) {
        if ([e[@"role"] isEqualToString:@"button"]) {
            NSString *label = e[@"label"];
            if ([label isEqualToString:@"Reject"] || [label isEqualToString:@"Approve"]) {
                NSLog(@"A11Y_AUTO: Found action button '%@' via a11y label", label);
            }
        }
    }
}

/// Generic card automation: navigate to ANY card and dump its a11y tree.
/// This can be parameterized to test any card in the sample set.
- (void)testA11yAutomation_InputForm
{
    NSLog(@"A11Y_AUTO: === Starting InputForm a11y automation ===");
    
    BOOL navigated = [self navigateToCardByA11y:@"v1.5" type:@"Scenarios" card:@"InputForm.json"];
    if (!navigated) {
        // Try v1.3 Elements path
        navigated = [self navigateToCardByA11y:@"v1.3" type:@"Elements" card:@"Input.Text.ErrorMessage.json"];
    }
    XCTAssertTrue(navigated, @"Should navigate to an input card via a11y labels");
    
    [self saveA11yState:@"auto_input_initial"];
    
    // Find text fields (input elements)
    NSArray *elements = [self discoverAccessibleElements];
    NSMutableArray *inputs = [NSMutableArray array];
    for (NSDictionary *e in elements) {
        if ([e[@"role"] isEqualToString:@"textField"] || [e[@"role"] isEqualToString:@"textView"]) {
            [inputs addObject:e];
            NSLog(@"A11Y_AUTO: Found input '%@' (id: '%@')", e[@"label"], e[@"identifier"]);
        }
    }
    NSLog(@"A11Y_AUTO: %lu input fields found on card", (unsigned long)inputs.count);
}



/// Toggle visibility double-fire validation.
/// Navigates to a ToggleVisibility card, taps the toggle, waits, and verifies
/// that the toggled content stays visible (not auto-collapsed by double-fire).
/// On iOS 26, the Gestures framework re-delivers touchesEnded twice — without
/// the _hasFiredActionForCurrentTouch guard, the toggle fires twice (open+close).
- (void)testToggleVisibilityDoubleFire
{
    NSLog(@"TOGGLE_DOUBLE_FIRE: === Starting toggle double-fire validation ===");

    // Navigate to the ToggleVisibility test card
    BOOL navigated = [self navigateToCardByA11y:@"v1.2" type:@"Elements" card:@"Action.ToggleVisibility.json"];
    if (!navigated) {
        // Fallback: try the Tests directory
        navigated = [self navigateToCardByA11y:@"v1.2" type:@"Tests" card:@"ToggleVisibility.AllElements.json"];
    }
    XCTAssertTrue(navigated, @"Should navigate to a ToggleVisibility card");

    // Capture initial state
    [self saveA11yState:@"toggle_initial"];
    NSArray *initialElements = [self discoverAccessibleElements];
    NSUInteger initialCount = initialElements.count;
    NSLog(@"TOGGLE_DOUBLE_FIRE: Initial element count: %lu", (unsigned long)initialCount);

    // Find a toggle-able element (button or tappable element)
    // Look for "Toggle!" or similar button labels
    BOOL tapped = NO;
    for (NSString *label in @[@"Toggle!", @"Toggle", @"Sources", @"Show", @"Expand"]) {
        if ([self tapByAccessibilityLabel:label]) {
            NSLog(@"TOGGLE_DOUBLE_FIRE: Tapped toggle button: '%@'", label);
            tapped = YES;
            break;
        }
    }

    if (!tapped) {
        // Try tapping the first button we find
        for (NSDictionary *e in initialElements) {
            if ([e[@"role"] isEqualToString:@"button"]) {
                NSString *label = e[@"label"];
                if ([self tapByAccessibilityLabel:label]) {
                    NSLog(@"TOGGLE_DOUBLE_FIRE: Tapped first available button: '%@'", label);
                    tapped = YES;
                    break;
                }
            }
        }
    }
    XCTAssertTrue(tapped, @"Should find and tap a toggle element");

    // Wait 2 seconds to let any double-fire settle
    // On the buggy path (no guard), the second touchesEnded fires within ~50ms
    // after the first one, so 2s is more than enough to see if it collapsed back
    [NSThread sleepForTimeInterval:2.0];

    // Capture post-toggle state
    [self saveA11yState:@"toggle_after_tap"];
    NSArray *afterElements = [self discoverAccessibleElements];
    NSUInteger afterCount = afterElements.count;
    NSLog(@"TOGGLE_DOUBLE_FIRE: After toggle element count: %lu", (unsigned long)afterCount);

    // The element count should have changed (expanded = more elements visible)
    // If the toggle fired twice (bug), count would be same as initial (collapsed back)
    if (afterCount != initialCount) {
        NSLog(@"TOGGLE_DOUBLE_FIRE: PASS — Element count changed from %lu to %lu (toggle persisted)",
              (unsigned long)initialCount, (unsigned long)afterCount);
    } else {
        NSLog(@"TOGGLE_DOUBLE_FIRE: WARNING — Element count unchanged (%lu). "
              "Toggle may have double-fired or card has no expandable content at this path.",
              (unsigned long)initialCount);
    }

    // Tap again to collapse — verify round-trip
    [NSThread sleepForTimeInterval:0.5];
    tapped = NO;
    for (NSString *label in @[@"Toggle!", @"Toggle", @"Sources", @"Hide", @"Collapse"]) {
        if ([self tapByAccessibilityLabel:label]) {
            tapped = YES;
            break;
        }
    }
    [NSThread sleepForTimeInterval:2.0];

    [self saveA11yState:@"toggle_after_second_tap"];
    NSArray *finalElements = [self discoverAccessibleElements];
    NSUInteger finalCount = finalElements.count;
    NSLog(@"TOGGLE_DOUBLE_FIRE: Final element count after 2nd tap: %lu", (unsigned long)finalCount);

    // After 2nd tap, should be back to initial state
    NSLog(@"TOGGLE_DOUBLE_FIRE: Round-trip test: initial=%lu, expanded=%lu, collapsed=%lu",
          (unsigned long)initialCount, (unsigned long)afterCount, (unsigned long)finalCount);
    NSLog(@"TOGGLE_DOUBLE_FIRE: === Test complete ===");
}


#pragma mark - A11YMAS Batch A/C: Name-Role + Focus-Retention Repro Scenarios

/// A-group helper: navigate to a card, optionally tap a label to expand
/// (e.g. a ShowCard), dump the a11y tree, and report whether each expected
/// control label is reachable with a non-generic accessible name.
/// Relaunch with the card rendered directly, bypassing the sample picker.
/// See -[ViewController loadSampleCardFromLaunchArgumentsIfPresent] for why: every picker
/// row shares one accessibility frame, so tapping a named row is racy and several
/// scenarios never reached their card.
/// WI#5536079 — confirm the ChoiceSet placeholder contrast Ashley Rocha reported.
///
/// This scenario exists to validate the harness, not the SDK. The reported 1.674:1 was
/// previously answered "not reproduced, measured 14.088:1" by an external tool that read
/// the text field's textColor - the colour typed text would use - rather than the
/// placeholder, which is a separate property drawn by UIKit in the system default. The
/// work item was closed on that reading and has since been reopened with a real fix.
///
/// The harness is only rectified once this run independently reports a placeholder ratio
/// close to the reported figure. Until then it is still blind to the same class of defect.
- (void)testA11yMAS_ChoiceSetPlaceholderContrast_5536079
{
    NSString *spec = @"v1.5/Scenarios/RestaurantOrder.json";
    [testApp terminate];
    // "both" captures light and dark from the same rendered card, so a divergent AA verdict
    // is attributable to colour resolution rather than to two separate launches.
    testApp.launchArguments = @[ @"ui-testing", @"-a11yCard", spec,
                                 @"-a11yColorDump", @"-a11yAppearance", @"both" ];
    [testApp launch];
    // Two appearance passes: 2s settle, then 1.5s per pass plus the walk. Generous so the
    // app is not torn down mid-dump.
    [NSThread sleepForTimeInterval:16.0];
    NSLog(@"A11YMAS_COLOR_SCENARIO: wi=5536079 card=%@", spec);
}

- (BOOL)launchDirectlyWithCard:(NSString *)version type:(NSString *)type card:(NSString *)card
{
    NSString *spec = [NSString stringWithFormat:@"%@/%@/%@", version, type, card];
    [testApp terminate];
    testApp.launchArguments = @[ @"ui-testing", @"-a11yCard", spec ];
    [testApp launch];

    // Wait for the card to render, but do NOT gate on a minimum element count.
    //
    // An earlier version required `count > 2`. That is wrong here: the defects under
    // test include a container collapsing to a SINGLE accessibility element - the Sev1
    // TooltipTestCard measured exactly n=1 on the unfixed tree. With a >2 gate that card
    // never satisfied the wait, the helper reported "no content", the scan fell back to
    // the racy picker, and the scenario never captured. The readiness check was hiding
    // precisely the defect it was meant to measure.
    //
    // Settle first so an async render is not sampled half-built, then accept whatever the
    // accessibility tree reports, however small.
    [NSThread sleepForTimeInterval:6.0];
    NSUInteger elementCount = [self discoverAccessibleElements].count;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20.0];
    while (elementCount == 0 && [deadline timeIntervalSinceNow] > 0) {
        [NSThread sleepForTimeInterval:1.0];
        elementCount = [self discoverAccessibleElements].count;
    }
    NSLog(@"A11Y_NAV: direct-loaded '%@' (%lu elements)", spec, (unsigned long)elementCount);
    return elementCount > 0;
}

- (void)a11ymasScanCard:(NSString *)version
                   type:(NSString *)type
                   card:(NSString *)card
          tapToExpand:(NSString *)expandLabel
              stateName:(NSString *)stateName
        expectedLabels:(NSArray<NSString *> *)expectedLabels
                     wi:(NSString *)wi
{
    // Direct load first; fall back to picker navigation if the hook is unavailable.
    BOOL navigated = [self launchDirectlyWithCard:version type:type card:card];
    if (!navigated) {
        navigated = [self navigateToCardByA11y:version type:type card:card];
    }
    XCTAssertTrue(navigated, @"A11YMAS WI#%@: should navigate to %@", wi, card);
    if (!navigated) { return; }

    if (expandLabel.length > 0) {
        if ([self tapByAccessibilityLabel:expandLabel]) {
            NSLog(@"A11YMAS_SCAN: WI#%@ expanded via '%@'", wi, expandLabel);
            [NSThread sleepForTimeInterval:1.5];
        } else {
            NSLog(@"A11YMAS_REPRO: WI#%@ expand control '%@' NOT reachable", wi, expandLabel);
        }
    }

    [self saveA11yState:stateName];
    NSArray *elements = [self discoverAccessibleElements];
    NSLog(@"A11YMAS_SCAN: WI#%@ card=%@ elements=%lu", wi, card, (unsigned long)elements.count);

    for (NSString *expected in expectedLabels) {
        BOOL found = NO;
        for (NSDictionary *e in elements) {
            if ([e[@"label"] rangeOfString:expected options:NSCaseInsensitiveSearch].location != NSNotFound) {
                found = YES;
                NSLog(@"A11YMAS_OK: WI#%@ '%@' present as role=%@ value='%@'",
                      wi, expected, e[@"role"], e[@"value"]);
                break;
            }
        }
        if (!found) {
            NSLog(@"A11YMAS_REPRO: WI#%@ missing accessible name/role: '%@'", wi, expected);
        }
    }
}

/// C-group helper: navigate, capture the pre-action a11y state, activate a
/// control by label, then capture the post-action state. Logs element counts and
/// the first few labels in reading order so focus movement after the action is
/// observable in the element trees + screenshots.
/// Tap the first *hittable* element carrying this exact label.
///
/// tapByAccessibilityLabel: subscripts by label, which is ambiguous when several elements
/// share one. ActionModeTestCard renders three "..." buttons and the first match is the
/// non-hittable `Root Overflow Actions (...)` container, so the subscript path failed and
/// WI#5536765 recorded no activation at all - only a _before state, never an _after.
- (BOOL)tapFirstHittableWithLabel:(NSString *)label
{
    NSPredicate *pred = [NSPredicate predicateWithFormat:@"label == %@", label];
    XCUIElementQuery *q = [[testApp descendantsMatchingType:XCUIElementTypeAny]
                           matchingPredicate:pred];
    NSUInteger count = q.count;
    for (NSUInteger i = 0; i < count && i < 20; i++) {
        XCUIElement *e = [q elementBoundByIndex:i];
        if ([e exists] && [e isHittable]) {
            [e tap];
            NSLog(@"A11Y_NAV: tapped '%@' (match %lu of %lu)",
                  label, (unsigned long)(i + 1), (unsigned long)count);
            return YES;
        }
    }
    return [self tapByAccessibilityLabel:label];
}

- (void)a11ymasActivate:(NSString *)version
                   type:(NSString *)type
                   card:(NSString *)card
            actionLabel:(NSString *)actionLabel
              thenLabel:(NSString *)thenLabel
              stateName:(NSString *)stateName
                     wi:(NSString *)wi
{
    // Direct load first. The sample picker gives every row an identical accessibility
    // frame, so isHittable is position-dependent and navigation is racy; a11ymasScanCard:
    // was moved to direct load for exactly that reason and these interaction helpers were
    // left behind. That is why WI#5532354 never produced a dump in any run - navigation
    // failed and the helper returned before saveA11yState:.
    BOOL navigated = [self launchDirectlyWithCard:version type:type card:card];
    if (!navigated) {
        navigated = [self navigateToCardByA11y:version type:type card:card];
    }
    XCTAssertTrue(navigated, @"A11YMAS WI#%@: should navigate to %@", wi, card);
    if (!navigated) { return; }

    [self saveA11yState:[NSString stringWithFormat:@"%@_before", stateName]];
    NSArray *before = [self discoverAccessibleElements];
    NSString *firstBefore = before.count > 0 ? before[0][@"label"] : @"(none)";
    NSLog(@"A11YMAS_FOCUS: WI#%@ before action: %lu elements, first='%@'",
          wi, (unsigned long)before.count, firstBefore);

    if (![self tapFirstHittableWithLabel:actionLabel]) {
        NSLog(@"A11YMAS_REPRO: WI#%@ action control '%@' NOT reachable", wi, actionLabel);
        return;
    }
    NSLog(@"A11YMAS_FOCUS: WI#%@ activated '%@'", wi, actionLabel);
    [NSThread sleepForTimeInterval:1.5];

    [self saveA11yState:[NSString stringWithFormat:@"%@_after", stateName]];
    NSArray *after = [self discoverAccessibleElements];
    NSString *firstAfter = after.count > 0 ? after[0][@"label"] : @"(none)";
    NSLog(@"A11YMAS_FOCUS: WI#%@ after action: %lu elements, first='%@'",
          wi, (unsigned long)after.count, firstAfter);

    // Second step. These bugs are about where focus lands once the transient UI goes
    // away, so the dismissal has to actually be performed - activating the control that
    // opens it and stopping there measures nothing the bug describes.
    if (thenLabel.length == 0) { return; }
    if (![self tapFirstHittableWithLabel:thenLabel]) {
        NSLog(@"A11YMAS_REPRO: WI#%@ dismiss control '%@' NOT reachable", wi, thenLabel);
        return;
    }
    NSLog(@"A11YMAS_FOCUS: WI#%@ dismissed via '%@'", wi, thenLabel);
    [NSThread sleepForTimeInterval:1.5];

    [self saveA11yState:[NSString stringWithFormat:@"%@_afterdismiss", stateName]];
    NSArray *dismissed = [self discoverAccessibleElements];
    NSString *firstDismissed = dismissed.count > 0 ? dismissed[0][@"label"] : @"(none)";
    XCUIElement *kbFocus = [[[testApp descendantsMatchingType:XCUIElementTypeAny]
        matchingPredicate:[NSPredicate predicateWithFormat:@"hasKeyboardFocus == true"]]
        elementBoundByIndex:0];
    NSString *focused = ([kbFocus exists] && kbFocus.label.length > 0) ? kbFocus.label : @"(none)";
    NSLog(@"A11YMAS_FOCUS: WI#%@ after dismiss: %lu elements, first='%@', keyboardFocus='%@'",
          wi, (unsigned long)dismissed.count, firstDismissed, focused);
}

// ===== A-group: missing accessible name / role =====

/// WI#5428631 / WI#5428632 — ShowCard ChoiceSet dropdown role + menu-item names.
- (void)testA11yMAS_FoodOrderShowCard_dropdown
{
    [self a11ymasScanCard:@"v1.5" type:@"Scenarios" card:@"FoodOrder.json"
              tapToExpand:@"Steak"
                stateName:@"a11ymas_5428632_foodorder_showcard"
           expectedLabels:@[ @"Rare", @"Medium-Rare", @"Well-done" ]
                       wi:@"5428632"];
}

/// WI#5539328 — ColumnSet.Input.ChoiceSet.VerticalStretch combo box accessible name.
- (void)testA11yMAS_ColumnSetChoiceSet_name
{
    [self a11ymasScanCard:@"v1.1" type:@"Tests" card:@"ColumnSet.Input.ChoiceSet.VerticalStretch.json"
              tapToExpand:nil
                stateName:@"a11ymas_5539328_columnset_choiceset"
           expectedLabels:@[ @"ChoiceSet" ]
                       wi:@"5539328"];
}

/// WI#5539505 — InputStyle: text field beside 'Est. Delivery' has no accessible name.
- (void)testA11yMAS_InputStyle_fieldName
{
    [self a11ymasScanCard:@"v1.6" type:@"Elements" card:@"InputStyle.json"
              tapToExpand:nil
                stateName:@"a11ymas_5539505_inputstyle"
           expectedLabels:@[ @"Est. Delivery", @"Product Name" ]
                       wi:@"5539505"];
}

/// WI#5532275 — CompoundButton role not announced.
- (void)testA11yMAS_CompoundButton_role
{
    [self a11ymasScanCard:@"v1.5" type:@"Scenarios" card:@"CompoundButtonSample.json"
              tapToExpand:nil
                stateName:@"a11ymas_5532275_compoundbutton"
           expectedLabels:@[ @"Summarize", @"View active work items", @"Give feedback" ]
                       wi:@"5532275"];
}

/// WI#5536877 — AdaptiveCard.Rtl.False: phantom 'button' announced with no visual control.
- (void)testA11yMAS_RtlFalse_phantomButton
{
    [self a11ymasScanCard:@"v1.5" type:@"Tests" card:@"AdaptiveCard.Rtl.False.json"
              tapToExpand:nil
                stateName:@"a11ymas_5536877_rtlfalse"
           expectedLabels:@[ @"Column 1", @"Column 2", @"Column 3" ]
                       wi:@"5536877"];
}

// ===== C-group: focus retention after action =====

/// WI#5526561 — ActivityUpdate: focus not retained when activating dismiss.
- (void)testA11yMAS_ActivityUpdate_dismissFocus
{
    // ActivityUpdate.json has exactly four actions - Set due date, Send, Comment, OK -
    // and no control named "dismiss". Re-activating the ShowCard toggle is what collapses
    // the expanded card, so that is the dismissal the bug can be describing. Previously
    // this scenario only expanded, and never exercised the dismissal at all.
    [self a11ymasActivate:@"v1.5" type:@"Scenarios" card:@"ActivityUpdate.json"
              actionLabel:@"Set due date"
                thenLabel:@"Set due date"
                stateName:@"a11ymas_5526561_activity_dismiss"
                       wi:@"5526561"];
}

/// WI#5536765 — ActionModeTestCard: focus not retained activating Cancel under More(...).
- (void)testA11yMAS_ActionMode_cancelFocus
{
    // The "Cancel" the bug names is not a card action - ActionModeTestCard.json has no
    // such title. It is the UIAlertAction that ACROverflowTarget.mm adds to the overflow
    // action sheet. So the interaction is two steps: open More (...), then Cancel.
    [self a11ymasActivate:@"v1.5" type:@"Tests" card:@"ActionModeTestCard.json"
              actionLabel:@"..."
                thenLabel:@"Cancel"
                stateName:@"a11ymas_5536765_actionmode_cancel"
                       wi:@"5536765"];
}


#pragma mark - A11YMAS Batch B: Swipe-Accessibility Repro Scenarios

/// Helper: navigate to a card, dump its a11y tree, and report whether any of the
/// expected control labels are reachable via VoiceOver. Logs A11YMAS_REPRO when a
/// expected control is NOT reachable (the swipe-accessibility bug), and A11YMAS_OK
/// when reachable (post-fix). Always dumps <name>_elements.json for the pipeline.
- (void)a11ymasScanCard:(NSString *)version
                   type:(NSString *)type
                   card:(NSString *)card
              stateName:(NSString *)stateName
        expectedLabels:(NSArray<NSString *> *)expectedLabels
                     wi:(NSString *)wi
{
    // Same racy-picker problem as a11ymasActivate: - the sample list gives every row
    // an identical accessibility frame, so isHittable is position-dependent. Direct
    // load first, picker only as a fallback.
    BOOL navigated = [self launchDirectlyWithCard:version type:type card:card];
    if (!navigated) {
        navigated = [self navigateToCardByA11y:version type:type card:card];
    }
    XCTAssertTrue(navigated, @"A11YMAS WI#%@: should navigate to %@", wi, card);
    if (!navigated) { return; }

    [self saveA11yState:stateName];
    NSArray *elements = [self discoverAccessibleElements];
    NSLog(@"A11YMAS_SCAN: WI#%@ card=%@ elements=%lu", wi, card, (unsigned long)elements.count);

    NSMutableSet *reachable = [NSMutableSet set];
    for (NSDictionary *e in elements) {
        if ([e[@"label"] length] > 0) { [reachable addObject:e[@"label"]]; }
    }
    for (NSString *expected in expectedLabels) {
        BOOL found = NO;
        for (NSString *label in reachable) {
            if ([label rangeOfString:expected options:NSCaseInsensitiveSearch].location != NSNotFound) {
                found = YES;
                break;
            }
        }
        if (found) {
            NSLog(@"A11YMAS_OK: WI#%@ reachable: '%@'", wi, expected);
        } else {
            NSLog(@"A11YMAS_REPRO: WI#%@ NOT reachable via swipe: '%@'", wi, expected);
        }
    }
}

/// WI#5535831 — RatingInput stars not reachable via swipe gesture.
- (void)testA11yMAS_RatingInput_swipe
{
    [self a11ymasScanCard:@"v1.5" type:@"Scenarios" card:@"RatingInput.json"
                stateName:@"a11ymas_5535831_rating_input"
           expectedLabels:@[ @"Rate 1 Star", @"Rate 3 Star", @"Rate 5 Star" ]
                       wi:@"5535831"];
}

/// WI#5533268 — FluentIcon.RTL icons ("RTL is supported") not reachable via swipe.
- (void)testA11yMAS_FluentIconRTL_swipe
{
    [self a11ymasScanCard:@"v1.5" type:@"Scenarios" card:@"FluentIcon.RTL.json"
                stateName:@"a11ymas_5533268_fluenticon_rtl"
           expectedLabels:@[ @"RTL is supported" ]
                       wi:@"5533268"];
}

/// WI#5536935 — TooltipTestCard controls not reachable via swipe (Sev1).
- (void)testA11yMAS_TooltipTestCard_swipe
{
    [self a11ymasScanCard:@"v1.5" type:@"Tests" card:@"TooltipTestCard.json"
                stateName:@"a11ymas_5536935_tooltip"
           expectedLabels:@[ @"Submit", @"Action" ]
                       wi:@"5536935"];
}

/// WI#5539230 — Input.Text.InlineAction: the inline action button's name.
///
/// The card carries two inline actions and no string "Inline Action" anywhere, so the
/// original expectation here could never match and logged a repro every run regardless of
/// behaviour. The real names are the Action.Submit's tooltip ("Send", icon-only, no title)
/// and the Action.OpenUrl's title ("Reply").
///
/// Note the scanner drops elements whose accessibility label is empty, so an unnamed
/// button is absent from the dump rather than present-and-blank. A missing "Send" button
/// IS the defect, not a gap in the capture.
- (void)testA11yMAS_InlineAction_buttonName
{
    [self a11ymasScanCard:@"v1.3" type:@"Elements" card:@"Input.Text.InlineAction.json"
                stateName:@"a11ymas_5539230_inlineaction"
           expectedLabels:@[ @"Send", @"Reply" ]
                       wi:@"5539230"];
}

/// WI#5539188 — InputLabelPosition 'Click here for action' link not reachable via swipe.
- (void)testA11yMAS_InputLabel_link_swipe
{
    // InputLabelPosition.json contains neither "Click here for action" nor any
    // RichTextBlock TextRun with a selectAction, so this scenario was scanning a card
    // without the construct under test - and expectedLabels then logged A11YMAS_REPRO
    // every run, which read like the bug reproducing. WI#5539188 names InputLabel.json,
    // which has four such TextRuns.
    [self a11ymasScanCard:@"v1.5" type:@"Elements" card:@"InputLabel.json"
                stateName:@"a11ymas_5539188_inputlabel_link"
           expectedLabels:@[ @"Click here for action" ]
                       wi:@"5539188"];
}


#pragma mark - A11YMAS Batch D: Keyboard-Accessibility Repro Scenarios

/// D-group helper: navigate to a card, then walk focus with the HW Tab key,
/// recording how many distinct controls receive keyboard focus. Logs
/// A11YMAS_KBD with the focused-element count so we can see whether interactive
/// controls are reachable via keyboard (the bug: count stays at 0 / does not
/// advance into the card).
- (void)a11ymasKeyboardWalk:(NSString *)version
                       type:(NSString *)type
                       card:(NSString *)card
                  stateName:(NSString *)stateName
                         wi:(NSString *)wi
{
    // Same racy-picker problem as a11ymasActivate: - the sample list gives every row
    // an identical accessibility frame, so isHittable is position-dependent. Direct
    // load first, picker only as a fallback.
    BOOL navigated = [self launchDirectlyWithCard:version type:type card:card];
    if (!navigated) {
        navigated = [self navigateToCardByA11y:version type:type card:card];
    }
    XCTAssertTrue(navigated, @"A11YMAS WI#%@: should navigate to %@", wi, card);
    if (!navigated) { return; }

    [self saveA11yState:stateName];

    // Drive the hardware keyboard: press Tab several times and capture which
    // element holds keyboard focus (hasKeyboardFocus) after each press.
    // Positive control. A bare distinctKeyboardFocusable=0 cannot tell us whether the
    // card's controls are unreachable or whether Tab simply does nothing in this harness,
    // so probe first and say which it is. If the probe also finds nothing, the result
    // below is UNMEASURABLE, not a reproduction.
    NSMutableSet *probeLabels = [NSMutableSet set];
    for (int i = 0; i < 6; i++) {
        [testApp typeKey:XCUIKeyboardKeyTab modifierFlags:XCUIKeyModifierNone];
        [NSThread sleepForTimeInterval:0.3];
        XCUIElement *pf = [[[testApp descendantsMatchingType:XCUIElementTypeAny]
            matchingPredicate:[NSPredicate predicateWithFormat:@"hasKeyboardFocus == true"]]
            elementBoundByIndex:0];
        if ([pf exists] && pf.label.length > 0) { [probeLabels addObject:pf.label]; }
    }
    NSLog(@"A11YMAS_KBD_PROBE: WI#%@ anythingFocusableAnywhere=%lu", wi,
          (unsigned long)probeLabels.count);
    for (NSString *l in probeLabels) {
        NSLog(@"A11YMAS_KBD_PROBE:   focus landed on: '%@'", l);
    }
    if (probeLabels.count == 0) {
        NSLog(@"A11YMAS_KBD_PROBE: WI#%@ Tab moved focus NOWHERE in the whole app - "
               "keyboard results for this run are UNMEASURABLE, not a repro", wi);
    }

    NSMutableSet *focusedLabels = [NSMutableSet set];
    for (int i = 0; i < 12; i++) {
        [testApp typeKey:XCUIKeyboardKeyTab modifierFlags:XCUIKeyModifierNone];
        [NSThread sleepForTimeInterval:0.3];
        XCUIElement *focused = [[[testApp descendantsMatchingType:XCUIElementTypeAny]
            matchingPredicate:[NSPredicate predicateWithFormat:@"hasKeyboardFocus == true"]]
            elementBoundByIndex:0];
        if ([focused exists] && focused.label.length > 0) {
            [focusedLabels addObject:focused.label];
        }
    }
    NSLog(@"A11YMAS_KBD: WI#%@ card=%@ distinctKeyboardFocusable=%lu",
          wi, card, (unsigned long)focusedLabels.count);
    for (NSString *l in focusedLabels) {
        NSLog(@"A11YMAS_KBD:   focusable: '%@'", l);
    }
    if (focusedLabels.count == 0) {
        NSLog(@"A11YMAS_REPRO: WI#%@ no card control reachable via keyboard Tab", wi);
    }
}

/// WI#5532354 — CompoundButtonSample controls not reachable via tab / ctrl+tab.
- (void)testA11yMAS_CompoundButton_keyboard
{
    [self a11ymasKeyboardWalk:@"v1.5" type:@"Scenarios" card:@"CompoundButtonSample.json"
                    stateName:@"a11ymas_5532354_compoundbutton_kbd"
                           wi:@"5532354"];
}

/// WI#5428636 — interactive controls (ActionModeTestCard actions) not keyboard-accessible.
- (void)testA11yMAS_Interactive_keyboard
{
    [self a11ymasKeyboardWalk:@"v1.5" type:@"Tests" card:@"ActionModeTestCard.json"
                    stateName:@"a11ymas_5428636_interactive_kbd"
                           wi:@"5428636"];
}

@end
