//
//  A11yOverlayUITests.m
//  ADCIOSVisualizerUITests
//
//  XCUITest that dumps the accessibility tree to JSON files and takes
//  screenshots at each interaction step. The accessibility data includes
//  element labels, values, traits, and frame coordinates — enabling
//  post-processing to draw bounding box overlays.
//

#import <XCTest/XCTest.h>

@interface A11yOverlayUITests : XCTestCase
@end

@implementation A11yOverlayUITests {
    XCUIApplication *testApp;
}

- (void)setUp {
    [super setUp];
    self.continueAfterFailure = YES;

    testApp = [[XCUIApplication alloc] init];
    testApp.launchArguments = @[@"ui-testing"];
    [testApp launch];
}

- (void)tearDown {
    [super tearDown];
}

#pragma mark - A11y Tree Dump

- (NSArray *)dumpAccessibilityTree:(XCUIElement *)root {
    NSMutableArray *elements = [NSMutableArray array];
    [self walkElement:root depth:0 into:elements];
    return elements;
}

- (void)walkElement:(XCUIElement *)element depth:(int)depth into:(NSMutableArray *)elements {
    // Get element properties
    NSString *label = element.label ?: @"";
    NSString *value = element.value ? [NSString stringWithFormat:@"%@", element.value] : @"";
    CGRect frame = element.frame;
    BOOL exists = element.exists;

    if (!exists) return;

    // Map element type to role string
    NSString *role = [self roleStringForType:element.elementType];

    // Only include elements with labels (meaningful accessibility elements)
    if (label.length > 0 && ![role isEqualToString:@"other"]) {
        NSDictionary *elemDict = @{
            @"label": label,
            @"value": value,
            @"role": role,
            @"frame": @{
                @"x": @(frame.origin.x),
                @"y": @(frame.origin.y),
                @"width": @(frame.size.width),
                @"height": @(frame.size.height)
            },
            @"enabled": @(element.isEnabled),
            @"depth": @(depth),
            @"traits": [self traitsStringForElement:element]
        };
        [elements addObject:elemDict];
    }

    // Recurse into children (limit depth to avoid infinite recursion)
    if (depth < 8) {
        NSArray *childTypes = @[
            @(XCUIElementTypeButton),
            @(XCUIElementTypeStaticText),
            @(XCUIElementTypeTextField),
            @(XCUIElementTypeTextView),
            @(XCUIElementTypeImage),
            @(XCUIElementTypeCell),
            @(XCUIElementTypeTable),
            @(XCUIElementTypeScrollView),
            @(XCUIElementTypeOther),
            @(XCUIElementTypeGroup),
        ];

        for (NSNumber *type in childTypes) {
            XCUIElementQuery *query = [element childrenMatchingType:[type unsignedIntegerValue]];
            NSUInteger count = query.count;
            for (NSUInteger i = 0; i < count && i < 50; i++) {
                XCUIElement *child = [query elementBoundByIndex:i];
                if (child.exists) {
                    [self walkElement:child depth:depth + 1 into:elements];
                }
            }
        }
    }
}

- (NSString *)roleStringForType:(XCUIElementType)type {
    switch (type) {
        case XCUIElementTypeButton: return @"button";
        case XCUIElementTypeStaticText: return @"text";
        case XCUIElementTypeTextField: return @"textField";
        case XCUIElementTypeTextView: return @"textView";
        case XCUIElementTypeImage: return @"image";
        case XCUIElementTypeCell: return @"cell";
        case XCUIElementTypeTable: return @"table";
        case XCUIElementTypeScrollView: return @"scrollView";
        case XCUIElementTypeSwitch: return @"switch";
        case XCUIElementTypeSlider: return @"slider";
        case XCUIElementTypeGroup: return @"group";
        case XCUIElementTypeApplication: return @"application";
        case XCUIElementTypeWindow: return @"window";
        default: return @"other";
    }
}

- (NSString *)traitsStringForElement:(XCUIElement *)element {
    NSMutableArray *traits = [NSMutableArray array];
    if (element.isEnabled) [traits addObject:@"enabled"];
    if (element.isSelected) [traits addObject:@"selected"];
    // XCUIElement doesn't expose raw traits, but we can check button/link
    if (element.elementType == XCUIElementTypeButton) [traits addObject:@"button"];
    if (element.elementType == XCUIElementTypeStaticText) [traits addObject:@"staticText"];
    if (element.elementType == XCUIElementTypeImage) [traits addObject:@"image"];
    return [traits componentsJoinedByString:@","];
}

#pragma mark - File Output

- (void)writeA11yTree:(NSArray *)elements named:(NSString *)name {
    // Write to /tmp/a11y-xcui/ so the CI pipeline can read it
    NSString *dir = @"/tmp/a11y-xcui";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSString *path = [NSString stringWithFormat:@"%@/%@_elements.json", dir, name];
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:elements
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
    if (jsonData) {
        [jsonData writeToFile:path atomically:YES];
        NSLog(@"A11Y_DUMP: %@ -> %lu elements -> %@", name, (unsigned long)elements.count, path);
    }
}

- (void)takeScreenshotNamed:(NSString *)name {
    XCUIScreenshot *screenshot = [XCUIScreen.mainScreen screenshot];
    NSString *dir = @"/tmp/a11y-xcui";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *path = [NSString stringWithFormat:@"%@/%@.png", dir, name];
    [screenshot.PNGRepresentation writeToFile:path atomically:YES];
    NSLog(@"A11Y_SCREENSHOT: %@ -> %@", name, path);
}

#pragma mark - Test: ActivityUpdate Card ShowCard

- (void)testActivityUpdateShowCard {
    // Navigate to ActivityUpdate card
    XCUIElementQuery *buttons = testApp.buttons;

    [buttons[@"v1.5"] tap];
    [NSThread sleepForTimeInterval:0.5];
    [buttons[@"Scenarios"] tap];
    [NSThread sleepForTimeInterval:0.5];

    XCUIElement *table = [testApp.tables elementBoundByIndex:1];
    [[table.staticTexts matchingIdentifier:@"ActivityUpdate.json"] elementBoundByIndex:0 tap];
    [NSThread sleepForTimeInterval:2.0];

    // Dump: card rendered state
    NSArray *tree1 = [self dumpAccessibilityTree:testApp];
    [self writeA11yTree:tree1 named:@"activity_card_rendered"];
    [self takeScreenshotNamed:@"activity_card_rendered"];

    XCTAssertGreaterThan(tree1.count, 5, @"Card should have multiple accessible elements");

    // Tap Comment ShowCard
    if ([buttons[@"Comment"] exists]) {
        [buttons[@"Comment"] tap];
        [NSThread sleepForTimeInterval:1.5];

        // Dump: ShowCard expanded
        NSArray *tree2 = [self dumpAccessibilityTree:testApp];
        [self writeA11yTree:tree2 named:@"showcard_comment_expanded"];
        [self takeScreenshotNamed:@"showcard_comment_expanded"];

        XCTAssertGreaterThan(tree2.count, tree1.count,
            @"Expanded ShowCard should have more elements than collapsed");
    }
}

- (void)testExpenseReportCard {
    // Navigate to ExpenseReport card
    XCUIElementQuery *buttons = testApp.buttons;

    // Reset first
    if ([buttons[@"Back"] exists]) [buttons[@"Back"] tap];
    [NSThread sleepForTimeInterval:0.5];
    if ([buttons[@"Delete All Cards"] exists]) [buttons[@"Delete All Cards"] tap];
    [NSThread sleepForTimeInterval:0.5];

    [buttons[@"v1.5"] tap];
    [NSThread sleepForTimeInterval:0.5];
    [buttons[@"Scenarios"] tap];
    [NSThread sleepForTimeInterval:0.5];

    XCUIElement *table = [testApp.tables elementBoundByIndex:1];
    [[table.staticTexts matchingIdentifier:@"ExpenseReport.json"] elementBoundByIndex:0 tap];
    [NSThread sleepForTimeInterval:2.0];

    // Dump: card rendered
    NSArray *tree = [self dumpAccessibilityTree:testApp];
    [self writeA11yTree:tree named:@"expense_card_rendered"];
    [self takeScreenshotNamed:@"expense_card_rendered"];

    XCTAssertGreaterThan(tree.count, 3, @"ExpenseReport should have accessible elements");
}

@end
