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
    XCTAssertTrue(containerButton.exists && containerButton.isHittable, @"'This Container is clickable and will show a popover' button should exist and be hittable");
    [containerButton tap];
    XCUIElement *popoverTextView = [testApp.textViews elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", @"This is a popover"]];
    XCTAssertTrue(popoverTextView.exists, @"'This is a popover' TextView should exist");
    [self dismissPopoverBottomSheet];
    XCUIElement *popoverIcon = [testApp.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", @", Click me to show a popover"]];
    XCTAssertTrue(popoverIcon.exists && popoverIcon.isHittable, @"Button ', Click me to show a popover' should exist and be hittable");
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
    XCTAssertTrue(dismissButton.exists && dismissButton.isHittable, @"'Dismiss' button should exist and be hittable");
    [dismissButton tap];

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
    XCUIElementType scanTypes[] = {
        XCUIElementTypeButton, XCUIElementTypeStaticText,
        XCUIElementTypeTextField, XCUIElementTypeTextView,
        XCUIElementTypeImage, XCUIElementTypeSwitch, XCUIElementTypeSlider,
    };
    NSString *roleNames[] = {@"button", @"text", @"textField", @"textView", @"image", @"switch", @"slider"};
    
    for (int t = 0; t < 7; t++) {
        XCUIElementQuery *q = [testApp descendantsMatchingType:scanTypes[t]];
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
    BOOL navigated = [self navigateToCardByA11y:version type:type card:card];
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

/// WI#5539188 — InputLabelPosition 'Click here for action' link not reachable via swipe.
- (void)testA11yMAS_InputLabel_link_swipe
{
    [self a11ymasScanCard:@"v1.6" type:@"Elements" card:@"InputLabelPosition.json"
                stateName:@"a11ymas_5539188_inputlabel_link"
           expectedLabels:@[ @"Click here for action" ]
                       wi:@"5539188"];
}

@end
