#import "FindWindowController.h"
#import "FFResultsViewController.h"
#import "FFStatusBarViewController.h"
#import "FFFolderMenu.h"
#import "CommonAncestor.h"
#import <OakAppKit/OakAppKit.h>
#import <OakAppKit/NSAlert Additions.h>
#import <OakAppKit/NSMenuItem Additions.h>
#import <OakAppKit/OakPasteboard.h>
#import <OakAppKit/OakPasteboardSelector.h>
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <OakAppKit/OakSyntaxFormatter.h>
#import <OakFoundation/NSString Additions.h>
#import <OakFoundation/OakHistoryList.h>
#import <OakFoundation/OakFoundation.h>
#import <MenuBuilder/MenuBuilder.h>
#import <Preferences/Keys.h>
#import <ns/ns.h>
#import <io/path.h>
#import <regexp/regexp.h>

NSString* const kUserDefaultsFolderOptionsKey     = @"Folder Search Options";
NSString* const kUserDefaultsFindResultsHeightKey = @"findResultsHeight";
NSString* const kUserDefaultsDefaultFindGlobsKey  = @"defaultFindInFolderGlobs";

@interface OakAutoSizingTextField : NSTextField
@property (nonatomic) NSSize myIntrinsicContentSize;
@end

@implementation OakAutoSizingTextField
- (NSSize)intrinsicContentSize
{
	return NSEqualSizes(self.myIntrinsicContentSize, NSZeroSize) ? [super intrinsicContentSize] : self.myIntrinsicContentSize;
}

- (void)updateIntrinsicContentSizeToEncompassString:(NSString*)aString
{
	NSTextFieldCell* cell = [self.cell copy];
	cell.stringValue = aString;

	self.myIntrinsicContentSize = NSMakeSize(NSViewNoIntrinsicMetric, MAX(22, MIN([cell cellSizeForBounds:NSMakeRect(0, 0, NSWidth([self bounds]), CGFLOAT_MAX)].height, 225)));
	[self invalidateIntrinsicContentSize];
}
@end

static OakAutoSizingTextField* OakCreateTextField (id <NSTextFieldDelegate> delegate, NSView* labelView, NSString* grammarName)
{
	OakAutoSizingTextField* res = [[OakAutoSizingTextField alloc] initWithFrame:NSZeroRect];
	res.font = OakControlFont();
	res.formatter = [[OakSyntaxFormatter alloc] initWithGrammarName:grammarName];
	[[res cell] setWraps:YES];
	res.accessibilityTitleUIElement = labelView;
	res.delegate = delegate;
	return res;
}

static NSButton* OakCreateHistoryButton (NSString* toolTip)
{
	NSButton* res = [[NSButton alloc] initWithFrame:NSZeroRect];
	res.bezelStyle = NSBezelStyleRoundedDisclosure;
	res.buttonType = NSMomentaryLightButton;
	res.title      = @"";
	res.toolTip    = toolTip;
	res.accessibilityLabel = toolTip;
	[res setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
	return res;
}

@interface FindWindowController () <NSTextFieldDelegate, NSWindowDelegate, NSMenuDelegate, NSPopoverDelegate, NSTextStorageDelegate>
{
	BOOL _ignoreWhitespace;
	NSGridView* _gridView;
	NSStackView* _actionButtonsStackView;
}
@property (nonatomic) FFStatusBarViewController* statusBarViewController;

@property (nonatomic) NSTextField*              findLabel;
@property (nonatomic) OakAutoSizingTextField*   findTextField;
@property (nonatomic) OakSyntaxFormatter*       findStringFormatter;
@property (nonatomic) NSButton*                 findHistoryButton;

@property (nonatomic) NSButton*                 countButton;

@property (nonatomic) NSTextField*              replaceLabel;
@property (nonatomic) OakAutoSizingTextField*   replaceTextField;
@property (nonatomic) OakSyntaxFormatter*       replaceStringFormatter;
@property (nonatomic) NSButton*                 replaceHistoryButton;

@property (nonatomic) NSTextField*              optionsLabel;
@property (nonatomic) NSButton*                 ignoreCaseCheckBox;
@property (nonatomic) NSButton*                 ignoreWhitespaceCheckBox;
@property (nonatomic) NSButton*                 regularExpressionCheckBox;
@property (nonatomic) NSButton*                 wrapAroundCheckBox;

@property (nonatomic) NSTextField*              whereLabel;
@property (nonatomic) NSPopUpButton*            wherePopUpButton;
@property (nonatomic) NSTextField*              matchingLabel;
@property (nonatomic) NSComboBox*               globTextField;
@property (nonatomic) NSPopUpButton*            actionsPopUpButton;

@property (nonatomic, readwrite) NSButton*      findAllButton;
@property (nonatomic, readwrite) NSButton*      replaceAllButton;
@property (nonatomic, readwrite) NSButton*      replaceButton;
@property (nonatomic, readwrite) NSButton*      replaceAndFindButton;
@property (nonatomic, readwrite) NSButton*      findPreviousButton;
@property (nonatomic, readwrite) NSButton*      findNextButton;
@property (nonatomic, readwrite) NSButton*      stopSearchButton;

@property (nonatomic) NSPopover*                findStringPopver;

@property (nonatomic) NSObjectController*       objectController;
@property (nonatomic) OakHistoryList*           globHistoryList;
@property (nonatomic) OakHistoryList*           recentFolders;
@property (nonatomic) NSMutableArray*           myConstraints;

@property (nonatomic, readonly) BOOL            canIgnoreWhitespace;
@property (nonatomic) CGFloat                   findResultsHeight;

@property (nonatomic) BOOL                      findStringUpdated;
@property (nonatomic) BOOL                      replaceStringUpdated;
@end

@implementation FindWindowController
+ (NSSet*)keyPathsForValuesAffectingCanIgnoreWhitespace  { return [NSSet setWithObject:@"regularExpression"]; }
+ (NSSet*)keyPathsForValuesAffectingIgnoreWhitespace     { return [NSSet setWithObject:@"regularExpression"]; }
+ (NSSet*)keyPathsForValuesAffectingCanEditGlob          { return [NSSet setWithObject:@"searchTarget"]; }
+ (NSSet*)keyPathsForValuesAffectingCanReplaceInDocument { return [NSSet setWithObject:@"searchTarget"]; }

+ (void)initialize
{
	[NSUserDefaults.standardUserDefaults registerDefaults:@{
		kUserDefaultsDefaultFindGlobsKey: @[ @"*", @"*.txt", @"*.{c,h}" ],
	}];
}

- (id)init
{
	NSRect r = [[NSScreen mainScreen] visibleFrame];
	if((self = [super initWithWindow:[[NSPanel alloc] initWithContentRect:NSMakeRect(NSMidX(r)-100, NSMidY(r)+100, 200, 200) styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable) backing:NSBackingStoreBuffered defer:NO]]))
	{
		_projectFolder = NSHomeDirectory();

		self.resultsViewController     = [[FFResultsViewController alloc] init];
		self.statusBarViewController   = [[FFStatusBarViewController alloc] init];

		self.window.frameAutosaveName  = @"Find";
		self.window.hidesOnDeactivate  = NO;
		self.window.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace|NSWindowCollectionBehaviorFullScreenAuxiliary;
		self.window.delegate           = self;
		self.window.restorable         = NO;

		self.findLabel                 = OakCreateLabel(@"Find:");
		self.findTextField             = OakCreateTextField(self, self.findLabel, @"source.regexp.oniguruma");
		self.findStringFormatter       = _findTextField.formatter;
		self.findHistoryButton         = OakCreateHistoryButton(@"Show Find History");
		self.countButton               = OakCreateButton(@"Σ", NSBezelStyleSmallSquare);

		self.countButton.toolTip = @"Show Results Count";
		self.countButton.accessibilityLabel = self.countButton.toolTip;

		self.replaceLabel              = OakCreateLabel(@"Replace:");
		self.replaceTextField          = OakCreateTextField(self, self.replaceLabel, @"textmate.format-string");
		self.replaceStringFormatter    = _replaceTextField.formatter;
		self.replaceHistoryButton      = OakCreateHistoryButton(@"Show Replace History");

		self.optionsLabel              = OakCreateLabel(@"Options:");

		self.ignoreCaseCheckBox        = OakCreateCheckBox(@"Ignore Case");
		self.ignoreWhitespaceCheckBox  = OakCreateCheckBox(@"Ignore Whitespace");
		self.regularExpressionCheckBox = OakCreateCheckBox(@"Regular Expression");
		self.wrapAroundCheckBox        = OakCreateCheckBox(@"Wrap Around");

		self.whereLabel                = OakCreateLabel(@"In:");
		self.wherePopUpButton          = OakCreatePopUpButton(NO, nil, self.whereLabel);
		self.matchingLabel             = OakCreateLabel(@"matching");
		self.globTextField             = OakCreateComboBox(self.matchingLabel);
		self.actionsPopUpButton        = OakCreateActionPopUpButton(YES /* bordered */);

		self.findAllButton             = OakCreateButton(@"Find All");
		self.replaceAllButton          = OakCreateButton(@"Replace All");
		self.replaceButton             = OakCreateButton(@"Replace");
		self.replaceAndFindButton      = OakCreateButton(@"Replace & Find");
		self.findPreviousButton        = OakCreateButton(@"Previous");
		self.findNextButton            = OakCreateButton(@"Next");

		[self updateWindowTitle];
		[self updateSearchInPopUpMenu];

		// =============================
		// = Create action pop-up menu =
		// =============================

		MBMenu const items = {
			{ /* Placeholder */ },
			{ @"Search",                               @selector(nop:)                                    },
			{ @"Binary Files",                         @selector(toggleSearchBinaryFiles:),   .indent = 1 },
			{ @"Hidden Folders",                       @selector(toggleSearchHiddenFolders:), .indent = 1 },
			{ @"Symbolic Links to Folders",            @selector(toggleSearchFolderLinks:),   .indent = 1 },
			{ @"Symbolic Links to Files",              @selector(toggleSearchFileLinks:),     .indent = 1 },
			{ /* -------- */ },
			{ @"Collapse Results",                     @selector(toggleCollapsedState:),      @"1", .modifierFlags = NSEventModifierFlagCommand|NSEventModifierFlagOption, .target = self.resultsViewController },
			{ @"Select Result",                        .delegate = self                                   },
			{ /* -------- */ },
			{ @"Copy Matching Parts",                  @selector(copyMatchingParts:)                      },
			{ @"Copy Matching Parts With Filenames",   @selector(copyMatchingPartsWithFilename:)          },
			{ @"Copy Entire Lines",                    @selector(copyEntireLines:)                        },
			{ @"Copy Entire Lines With Filenames",     @selector(copyEntireLinesWithFilename:)            },
			{ @"Copy Replacements",                    @selector(copyReplacements:)                       },
			{ /* -------- */ },
			{ @"Check All",                            @selector(checkAll:)                               },
			{ @"Uncheck All",                          @selector(uncheckAll:)                             },
		};

		if(NSMenu* actionMenu = MBCreateMenu(items))
			self.actionsPopUpButton.menu = actionMenu;

		// =============================

		self.findHistoryButton.action     = @selector(showFindHistory:);
		self.replaceHistoryButton.action  = @selector(showReplaceHistory:);
		self.countButton.action           = @selector(countOccurrences:);
		self.findAllButton.action         = @selector(findAll:);
		self.replaceAllButton.action      = @selector(replaceAll:);
		self.replaceButton.action         = @selector(replace:);
		self.replaceAndFindButton.action  = @selector(replaceAndFind:);
		self.findPreviousButton.action    = @selector(findPrevious:);
		self.findNextButton.action        = @selector(findNext:);

		self.statusBarViewController.stopAction = @selector(stopSearch:);
		self.statusBarViewController.stopTarget = Find.sharedInstance;

		self.objectController = [[NSObjectController alloc] initWithContent:self];
		self.globHistoryList  = [[OakHistoryList alloc] initWithName:@"Find in Folder Globs.default" stackSize:10 fallbackUserDefaultsKey:kUserDefaultsDefaultFindGlobsKey];
		self.recentFolders    = [[OakHistoryList alloc] initWithName:@"findRecentPlaces" stackSize:21];

		[self.findTextField             bind:NSValueBinding         toObject:_objectController withKeyPath:@"content.findString"           options:@{ NSContinuouslyUpdatesValueBindingOption: @YES }];
		[self.replaceTextField          bind:NSValueBinding         toObject:_objectController withKeyPath:@"content.replaceString"        options:@{ NSContinuouslyUpdatesValueBindingOption: @YES }];
		[self.globTextField             bind:NSValueBinding         toObject:_objectController withKeyPath:@"content.globHistoryList.head" options:nil];
		[self.globTextField             bind:NSContentValuesBinding toObject:_objectController withKeyPath:@"content.globHistoryList.list" options:nil];
		[self.globTextField             bind:NSEnabledBinding       toObject:_objectController withKeyPath:@"content.canEditGlob"          options:nil];
		[self.ignoreCaseCheckBox        bind:NSValueBinding         toObject:_objectController withKeyPath:@"content.ignoreCase"           options:nil];
		[self.ignoreWhitespaceCheckBox  bind:NSValueBinding         toObject:_objectController withKeyPath:@"content.ignoreWhitespace"     options:nil];
		[self.regularExpressionCheckBox bind:NSValueBinding         toObject:_objectController withKeyPath:@"content.regularExpression"    options:nil];
		[self.wrapAroundCheckBox        bind:NSValueBinding         toObject:_objectController withKeyPath:@"content.wrapAround"           options:nil];
		[self.ignoreWhitespaceCheckBox  bind:NSEnabledBinding       toObject:_objectController withKeyPath:@"content.canIgnoreWhitespace"  options:nil];
		[self.replaceButton             bind:NSEnabledBinding       toObject:_objectController withKeyPath:@"content.canReplaceInDocument" options:nil];
		[self.replaceAndFindButton      bind:NSEnabledBinding       toObject:_objectController withKeyPath:@"content.canReplaceInDocument" options:nil];

		[self.countButton               bind:NSEnabledBinding       toObject:_objectController withKeyPath:@"content.findString.length"    options:nil];
		[self.findAllButton             bind:NSEnabledBinding       toObject:_objectController withKeyPath:@"content.findString.length"    options:nil];
		[self.replaceAllButton          bind:NSEnabledBinding       toObject:_objectController withKeyPath:@"content.findString.length"    options:nil];
		[self.replaceAndFindButton      bind:@"enabled2"            toObject:_objectController withKeyPath:@"content.findString.length"    options:nil];
		[self.findPreviousButton        bind:NSEnabledBinding       toObject:_objectController withKeyPath:@"content.findString.length"    options:nil];
		[self.findNextButton            bind:NSEnabledBinding       toObject:_objectController withKeyPath:@"content.findString.length"    options:nil];

		[self.resultsViewController     bind:@"replaceString"       toObject:_objectController withKeyPath:@"content.replaceString"        options:nil];

		NSView* contentView = self.window.contentView;
		OakAddAutoLayoutViewsToSuperview([self.allViews allValues], contentView);

		[self updateConstraints];

		self.window.defaultButtonCell = self.findNextButton.cell;

		// setup find/replace strings/options
		[self userDefaultsDidChange:nil];
		[self findClipboardDidChange:nil];
		[self replaceClipboardDidChange:nil];

		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(userDefaultsDidChange:) name:NSUserDefaultsDidChangeNotification object:NSUserDefaults.standardUserDefaults];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(findClipboardDidChange:) name:OakPasteboardDidChangeNotification object:OakPasteboard.findPasteboard];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(replaceClipboardDidChange:) name:OakPasteboardDidChangeNotification object:OakPasteboard.replacePasteboard];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(textViewWillPerformFindOperation:) name:@"OakTextViewWillPerformFindOperation" object:nil];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resultsFrameDidChange:) name:NSViewFrameDidChangeNotification object:self.resultsViewController.view];

		// Register to application activation/deactivation notification so we can tweak our collection behavior
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidActivate:) name:NSApplicationDidBecomeActiveNotification object:nil];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidDeactivate:) name:NSApplicationDidResignActiveNotification object:nil];

		[self.window addObserver:self forKeyPath:@"firstResponder" options:0 context:NULL];
	}
	return self;
}

- (void)dealloc
{
	[self.window removeObserver:self forKeyPath:@"firstResponder"];
	[NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)applicationDidActivate:(NSNotification*)notification
{
	// Starting with 10.11 behavior must be changed after current event loop cycle <rdar://23587833>
	dispatch_async(dispatch_get_main_queue(), ^{
		self.window.collectionBehavior |= NSWindowCollectionBehaviorMoveToActiveSpace;
	});
}

- (void)applicationDidDeactivate:(NSNotification*)notification
{
	// Starting with 10.11 behavior must be changed after current event loop cycle <rdar://23587833>
	dispatch_async(dispatch_get_main_queue(), ^{
		self.window.collectionBehavior &= ~NSWindowCollectionBehaviorMoveToActiveSpace;
	});
}

- (void)menuNeedsUpdate:(NSMenu*)aMenu
{
	[aMenu removeAllItems];
	[NSApp sendAction:@selector(updateShowTabMenu:) to:nil from:aMenu];
}

- (NSGridView*)gridView
{
	if(!_gridView)
	{
		NSGridView* optionsGridView = [NSGridView gridViewWithViews:@[
			@[ self.regularExpressionCheckBox, self.ignoreWhitespaceCheckBox ],
			@[ self.ignoreCaseCheckBox,        self.wrapAroundCheckBox       ],
		]];

		optionsGridView.rowSpacing    = 8;
		optionsGridView.columnSpacing = 20;
		optionsGridView.rowAlignment  = NSGridRowAlignmentFirstBaseline;

		NSStackView* whereStackView = [NSStackView stackViewWithViews:@[
			self.wherePopUpButton, self.matchingLabel, self.globTextField
		]];
		whereStackView.alignment = NSLayoutAttributeLastBaseline;
		[whereStackView setHuggingPriority:NSLayoutPriorityWindowSizeStayPut forOrientation:NSLayoutConstraintOrientationVertical];

		_gridView = [NSGridView gridViewWithViews:@[
			@[ self.findLabel,    self.findTextField,    self.findHistoryButton,   self.countButton ],
			@[ self.replaceLabel, self.replaceTextField, self.replaceHistoryButton                  ],
			@[ self.optionsLabel, optionsGridView                                                   ],
			@[ self.whereLabel,   whereStackView,        self.actionsPopUpButton                    ],
		]];

		_gridView.rowSpacing    = 8;
		_gridView.columnSpacing = 4;
		_gridView.rowAlignment  = NSGridRowAlignmentFirstBaseline;

		[_gridView rowAtIndex:0].topPadding        = 20;
		[_gridView rowAtIndex:2].bottomPadding     = 12;
		[_gridView columnAtIndex:0].xPlacement     = NSGridCellPlacementTrailing;
		[_gridView columnAtIndex:0].leadingPadding = 20;
		[_gridView columnAtIndex:1].leadingPadding = 4;
		[_gridView columnAtIndex:3].leadingPadding = 4;
		[_gridView columnAtIndex:_gridView.numberOfColumns-1].trailingPadding = 20;

		[_gridView cellAtColumnIndex:2 rowIndex:0].yPlacement = NSGridCellPlacementTop;
		[_gridView cellAtColumnIndex:3 rowIndex:0].yPlacement = NSGridCellPlacementTop;
		[_gridView cellAtColumnIndex:2 rowIndex:1].yPlacement = NSGridCellPlacementTop;

		[_gridView mergeCellsInHorizontalRange:NSMakeRange(2, 2) verticalRange:NSMakeRange(3, 1)];
		[_gridView cellAtColumnIndex:2 rowIndex:3].xPlacement = NSGridCellPlacementFill;

		[_gridView rowAtIndex:3].rowAlignment = NSGridRowAlignmentNone;
		[_gridView rowAtIndex:3].yPlacement   = NSGridCellPlacementCenter;

		NSDictionary<NSNumber*, NSView*>* baselineViews = @{ @2: self.regularExpressionCheckBox, @3: self.matchingLabel };
		for(NSNumber* row in baselineViews)
		{
			NSGridCell* gridCell = [_gridView cellAtColumnIndex:0 rowIndex:row.integerValue];
			gridCell.rowAlignment = NSGridRowAlignmentNone;
			gridCell.yPlacement   = NSGridCellPlacementNone;
			gridCell.customPlacementConstraints = @[ [gridCell.contentView.firstBaselineAnchor constraintEqualToAnchor:baselineViews[row].firstBaselineAnchor constant:0] ];
		}

		[_gridView setContentHuggingPriority:NSLayoutPriorityWindowSizeStayPut forOrientation:NSLayoutConstraintOrientationVertical];

		[self.countButton.widthAnchor constraintEqualToAnchor:self.findHistoryButton.widthAnchor].active = YES;
		[self.countButton.heightAnchor constraintEqualToAnchor:self.findHistoryButton.heightAnchor].active = YES;
		[self.wherePopUpButton addConstraint:[NSLayoutConstraint constraintWithItem:self.wherePopUpButton attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationLessThanOrEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:150]];
	}
	return _gridView;
}

- (NSStackView*)actionButtonsStackView
{
	if(!_actionButtonsStackView)
	{
		_actionButtonsStackView = [NSStackView stackViewWithViews:@[ self.findAllButton, self.replaceAllButton ]];
		[_actionButtonsStackView setViews:@[ self.replaceButton, self.replaceAndFindButton, self.findPreviousButton, self.findNextButton ] inGravity:NSStackViewGravityTrailing];
		[_actionButtonsStackView setHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationVertical];
	}
	return _actionButtonsStackView;
}

- (NSDictionary*)allViews
{
	NSDictionary* views = @{
		@"gridView":          self.gridView,
		@"results":           self.showsResultsOutlineView ? self.resultsViewController.view : [NSNull null],
		@"status":            self.statusBarViewController.view,
		@"actions":           self.actionButtonsStackView,
	};
	return views;
}

#ifndef CONSTRAINT
#define CONSTRAINT(str, align) [_myConstraints addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:str options:align metrics:nil views:views]]
#endif

- (void)updateConstraints
{
	if(_myConstraints)
		[self.window.contentView removeConstraints:_myConstraints];
	self.myConstraints = [NSMutableArray array];

	NSDictionary* views = self.allViews;

	CONSTRAINT(@"H:|[gridView]|", 0);

	if(self.showsResultsOutlineView)
	{
		CONSTRAINT(@"H:|[results]|", 0);
		[_myConstraints addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[gridView]-[results(>=50,==height@490)]-(8)-[status]" options:0 metrics:@{ @"height": @(self.findResultsHeight) } views:views]];
	}
	else
	{
		CONSTRAINT(@"V:|[gridView]-(8)-[status]", 0);
	}

	CONSTRAINT(@"H:|-[status]-|", 0);
	CONSTRAINT(@"H:|-[actions]-|", 0);
	CONSTRAINT(@"V:[status]-(8)-[actions]-|", 0);

	[self.window.contentView addConstraints:_myConstraints];

	if(self.showsResultsOutlineView)
			OakSetupKeyViewLoop(@[ self.findTextField, self.replaceTextField, self.countButton, self.regularExpressionCheckBox, self.ignoreWhitespaceCheckBox, self.ignoreCaseCheckBox, self.wrapAroundCheckBox, self.wherePopUpButton, self.globTextField, self.actionsPopUpButton, self.resultsViewController.outlineView, self.findAllButton, self.replaceAllButton, self.replaceButton, self.replaceAndFindButton, self.findPreviousButton, self.findNextButton ]);
	else	OakSetupKeyViewLoop(@[ self.findTextField, self.replaceTextField, self.countButton, self.regularExpressionCheckBox, self.ignoreWhitespaceCheckBox, self.ignoreCaseCheckBox, self.wrapAroundCheckBox, self.wherePopUpButton, self.globTextField, self.actionsPopUpButton, self.findAllButton, self.replaceAllButton, self.replaceButton, self.replaceAndFindButton, self.findPreviousButton, self.findNextButton ]);
}

- (void)userDefaultsDidChange:(NSNotification*)aNotification
{
	self.ignoreCase = [NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsFindIgnoreCase];
	self.wrapAround = [NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsFindWrapAround];

	NSDictionary* options = [NSUserDefaults.standardUserDefaults dictionaryForKey:kUserDefaultsFolderOptionsKey];
	self.searchHiddenFolders = [[options objectForKey:@"searchHiddenFolders"] boolValue];
	self.searchFolderLinks   = [[options objectForKey:@"searchFolderLinks"] boolValue];
	self.searchFileLinks     = ![[options objectForKey:@"skipFileLinks"] boolValue];
	self.searchBinaryFiles   = [[options objectForKey:@"searchBinaryFiles"] boolValue];
}

- (void)findClipboardDidChange:(NSNotification*)aNotification
{
	OakPasteboardEntry* entry = [OakPasteboard.findPasteboard current];
	self.findString        = entry.string;
	self.regularExpression = entry.regularExpression;
	self.ignoreWhitespace  = entry.ignoreWhitespace;
	self.fullWords         = entry.fullWordMatch;
	self.findStringUpdated = NO;
}

- (void)replaceClipboardDidChange:(NSNotification*)aNotification
{
	self.replaceString        = [[OakPasteboard.replacePasteboard current] string];
	self.replaceStringUpdated = NO;
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
	if([keyPath isEqualToString:@"firstResponder"])
	{
		NSResponder* firstResponder = [self.window firstResponder];
		self.resultsViewController.showReplacementPreviews = firstResponder == self.replaceTextField || firstResponder == self.replaceTextField.currentEditor;

		if([firstResponder isKindOfClass:[NSTextView class]])
		{
			NSTextView* textView = (NSTextView*)firstResponder;
			if(textView.isFieldEditor)
			{
				BOOL enable = _findTextField.currentEditor || _replaceTextField.currentEditor;
				if(textView.textStorage.delegate = enable ? self : nil)
					[self addStylesToFieldEditor];
			}
		}
	}
}

- (void)updateWindowTitle
{
	if(NSString* folder = self.searchFolder)
		self.window.title = [NSString localizedStringWithFormat:@"Find — %@", [folder stringByAbbreviatingWithTildeInPath]];
	else if(_searchTarget == FFSearchTargetOpenFiles)
		self.window.title = @"Find — Open Files";
	else
		self.window.title = @"Find";
}

- (void)showWindow:(id)sender
{
	BOOL isVisibleAndKey = [self isWindowLoaded] && [self.window isVisible] && [self.window isKeyWindow];
	[super showWindow:sender];
	if(!isVisibleAndKey || ![[self.window firstResponder] isKindOfClass:[NSTextView class]])
		[self.window makeFirstResponder:self.findTextField];
}

- (BOOL)commitEditing
{
	id currentResponder = [[self window] firstResponder];
	id view = [currentResponder isKindOfClass:[NSTextView class]] ? [currentResponder delegate] : currentResponder;
	BOOL res = [self.objectController commitEditing];
	if([[self window] firstResponder] != currentResponder && view)
		[[self window] makeFirstResponder:view];

	// =====================
	// = Update Pasteboard =
	// =====================

	if(_findStringUpdated && OakNotEmptyString(_findString))
	{
		NSDictionary* newOptions = @{
			OakFindRegularExpressionOption: @(self.regularExpression),
			OakFindIgnoreWhitespaceOption:  @(self.ignoreWhitespace),
			OakFindFullWordsOption:         @(self.fullWords),
		};

		[OakPasteboard.findPasteboard addEntryWithString:_findString options:newOptions];
		_findStringUpdated = NO;
	}

	if(_replaceStringUpdated && _replaceString)
	{
		[OakPasteboard.replacePasteboard addEntryWithString:_replaceString];
		_replaceStringUpdated = NO;
	}

	return res;
}

- (void)resultsFrameDidChange:(NSNotification*)aNotification
{
	if(self.showsResultsOutlineView)
		self.findResultsHeight = NSHeight(self.resultsViewController.view.frame);
}

- (void)windowDidResignKey:(NSNotification*)aNotification
{
	[self commitEditing];
}

- (void)windowWillClose:(NSNotification*)aNotification
{
	[self commitEditing];
}

- (void)textViewWillPerformFindOperation:(NSNotification*)aNotification
{
	if([self isWindowLoaded] && [self.window isVisible] && [self.window isKeyWindow])
		[self commitEditing];
}

// ==============================
// = Create “where” pop-up menu =
// ==============================

- (NSString*)displayNameForFolder:(NSString*)path
{
	std::vector<std::string> paths;
	for(NSUInteger i = 0; i < [self.recentFolders count]; ++i)
		paths.push_back(to_s([self.recentFolders objectAtIndex:i]));
	if(NSString* folder = self.searchFolder)
		paths.push_back(to_s(folder));
	paths.push_back(to_s(self.projectFolder));

	auto it = std::find(paths.begin(), paths.end(), to_s(path));
	if(it != paths.end())
		return [NSString stringWithCxxString:path::display_name(*it, path::disambiguate(paths)[it - paths.begin()])];
	return [NSFileManager.defaultManager displayNameAtPath:path];
}

- (void)updateSearchInPopUpMenu
{
	NSMenu* whereMenu = _wherePopUpButton.menu;
	[whereMenu removeAllItems];

	NSMenuItem* documentItem    = [whereMenu addItemWithTitle:@"Document"           action:@selector(takeSearchTargetFrom:) keyEquivalent:@"f"];
	NSMenuItem* selectionItem   = [whereMenu addItemWithTitle:@"Selection"          action:@selector(takeSearchTargetFrom:) keyEquivalent:@""];
	[whereMenu addItem:[NSMenuItem separatorItem]];
	NSMenuItem* openFilesItem   = [whereMenu addItemWithTitle:@"Open Files"         action:@selector(takeSearchTargetFrom:) keyEquivalent:@""];
	NSMenuItem* projectItem     = [whereMenu addItemWithTitle:@"Project Folder"     action:@selector(takeSearchTargetFrom:) keyEquivalent:@"F"];
	NSMenuItem* fileBrowserItem = [whereMenu addItemWithTitle:@"File Browser Items" action:@selector(takeSearchTargetFrom:) keyEquivalent:@""];
	NSMenuItem* otherItem       = [whereMenu addItemWithTitle:@"Other Folder…"      action:@selector(showFolderSelectionPanel:) keyEquivalent:@""];
	[whereMenu addItem:[NSMenuItem separatorItem]];
	NSMenuItem* folderItem      = [whereMenu addItemWithTitle:@"«Last Folder»"      action:@selector(takeSearchTargetFrom:) keyEquivalent:@""];
	[whereMenu addItem:[NSMenuItem separatorItem]];

	documentItem.tag    = FFSearchTargetDocument;
	selectionItem.tag   = FFSearchTargetSelection;
	openFilesItem.tag   = FFSearchTargetOpenFiles;
	projectItem.tag     = FFSearchTargetProject;
	fileBrowserItem.tag = FFSearchTargetFileBrowserItems;
	otherItem.tag       = FFSearchTargetOther;

	NSString* lastFolder = self.searchFolder ?: self.projectFolder;
	if(lastFolder)
	{
		[folderItem setTitle:[self displayNameForFolder:lastFolder]];
		[folderItem setIconForFile:lastFolder];
		[folderItem setRepresentedObject:lastFolder];
		[FFFolderMenu addFolderSubmenuToMenuItem:folderItem];
	}

	if(_searchTarget == FFSearchTargetProject || _searchTarget == FFSearchTargetOther || (_searchTarget == FFSearchTargetFileBrowserItems && _fileBrowserItems.count == 1))
			[_wherePopUpButton selectItem:folderItem];
	else	[_wherePopUpButton selectItemWithTag:_searchTarget];

	// =================
	// = Recent Places =
	// =================

	[whereMenu addItem:[NSMenuItem separatorItem]];
	[whereMenu addItemWithTitle:@"Recent Places" action:@selector(nop:) keyEquivalent:@""];

	for(NSUInteger i = 0; i < [self.recentFolders count]; ++i)
	{
		NSString* path = [self.recentFolders objectAtIndex:i];
		if([path isEqualToString:lastFolder] || [path isEqualToString:self.projectFolder])
			continue;
		if(![NSFileManager.defaultManager fileExistsAtPath:path])
			continue;

		NSMenuItem* recentItem = [whereMenu addItemWithTitle:[self displayNameForFolder:path] action:@selector(takeSearchTargetFrom:) keyEquivalent:@""];
		[recentItem setIconForFile:path];
		[recentItem setRepresentedObject:path];
	}
}

- (void)setSearchTarget:(FFSearchTarget)newTarget
{
	_searchTarget = newTarget;

	BOOL isFolderSearch = _searchTarget != FFSearchTargetDocument && _searchTarget != FFSearchTargetSelection;
	self.showsResultsOutlineView = isFolderSearch;

	BOOL isDirectory = NO;
	if(_searchTarget == FFSearchTargetOther && [NSFileManager.defaultManager fileExistsAtPath:self.otherFolder isDirectory:&isDirectory] && isDirectory)
		[self.recentFolders addObject:self.otherFolder];

	[self updateSearchInPopUpMenu];
	[self updateWindowTitle];
}

- (void)takeSearchTargetFrom:(NSMenuItem*)menuItem
{
	if(NSString* folder = menuItem.representedObject)
	{
		self.otherFolder = folder;
		self.searchTarget = FFSearchTargetOther;
	}
	else
	{
		self.searchTarget = FFSearchTarget(menuItem.tag);
	}
}

// ==============================

- (IBAction)showFindHistory:(id)sender
{
	if(![[OakPasteboardSelector.sharedInstance window] isVisible])
		[OakPasteboard.findPasteboard selectItemForControl:self.findTextField];
	// if the panel is visible it will automatically be hidden due to the mouse click
}

- (IBAction)showReplaceHistory:(id)sender
{
	if(![[OakPasteboardSelector.sharedInstance window] isVisible])
		[OakPasteboard.replacePasteboard selectItemForControl:self.replaceTextField];
	// if the panel is visible it will automatically be hidden due to the mouse click
}

- (void)popoverDidClose:(NSNotification*)aNotification
{
	self.findErrorString = nil;
}

- (void)setFindErrorString:(NSString*)aString
{
	if(_findErrorString == aString || [_findErrorString isEqualToString:aString])
		return;

	if(_findErrorString = aString)
	{
		if(!self.findStringPopver)
		{
			NSViewController* viewController = [NSViewController new];
			viewController.view = OakCreateLabel();

			self.findStringPopver = [NSPopover new];
			self.findStringPopver.behavior = NSPopoverBehaviorTransient;
			self.findStringPopver.contentViewController = viewController;
			self.findStringPopver.delegate = self;
		}

		NSTextField* textField = (NSTextField*)self.findStringPopver.contentViewController.view;
		textField.stringValue = _findErrorString;
		[textField sizeToFit];

		[self.findStringPopver showRelativeToRect:NSZeroRect ofView:self.findTextField preferredEdge:NSMaxYEdge];
	}
	else
	{
		[self.findStringPopver close];
		self.findStringPopver = nil;
	}
}

- (void)updateFindErrorString
{
	NSString* errorString = nil;
	if(self.regularExpression)
	{
		std::string const& error = regexp::validate(to_s(self.findString));
		if(error != NULL_STR)
			errorString = [NSString stringWithCxxString:text::format("Invalid regular expression: %s.", error.c_str())];
	}
	self.findErrorString = errorString;
}

- (void)setShowsResultsOutlineView:(BOOL)flag
{
	if(_showsResultsOutlineView == flag)
		return;

	BOOL isWindowLoaded = [self isWindowLoaded];
	CGFloat desiredHeight = self.findResultsHeight;

	NSView* view = self.resultsViewController.view;
	if(_showsResultsOutlineView = flag)
			OakAddAutoLayoutViewsToSuperview(@[ view ], self.window.contentView);
	else	[view removeFromSuperview];

	[self updateConstraints];

	if(flag && isWindowLoaded)
	{
		[self.window layoutIfNeeded];

		NSRect screenFrame = [[self.window screen] visibleFrame];
		NSRect windowFrame = self.window.frame;
		CGFloat minY = NSMinY(windowFrame);
		CGFloat maxY = NSMaxY(windowFrame);

		CGFloat currentHeight = NSHeight(self.resultsViewController.view.frame);
		minY -= desiredHeight - currentHeight;

		if(minY < NSMinY(screenFrame))
			maxY += NSMinY(screenFrame) - minY;
		if(maxY > NSMaxY(screenFrame))
			minY -= maxY - NSMaxY(screenFrame);

		minY = MAX(minY, NSMinY(screenFrame));
		maxY = MIN(maxY, NSMaxY(screenFrame));

		windowFrame.origin.y    = minY;
		windowFrame.size.height = maxY - minY;

		[self.window setFrame:windowFrame display:YES];
	}

	self.window.defaultButtonCell = flag ? self.findAllButton.cell : self.findNextButton.cell;
}

- (void)setBusy:(BOOL)busyFlag
{
	_busy = busyFlag;
	self.statusBarViewController.progressIndicatorVisible = busyFlag;
}

- (void)setStatusString:(NSString*)aString
{
	_statusString = aString;
	self.statusBarViewController.statusText = _statusString;
}

- (void)setAlternateStatusString:(NSString*)aString
{
	_alternateStatusString = aString;
	self.statusBarViewController.alternateStatusText = _alternateStatusString;
}

- (NSString*)searchFolder
{
	if(_searchTarget == FFSearchTargetProject)
		return self.projectFolder;
	else if(_searchTarget == FFSearchTargetFileBrowserItems && _fileBrowserItems.count == 1)
		return _fileBrowserItems.firstObject;
	else if(_searchTarget == FFSearchTargetOther)
		return self.otherFolder;
	return nil;
}

- (IBAction)goToParentFolder:(id)sender
{
	if(_searchTarget == FFSearchTargetFileBrowserItems && _fileBrowserItems.count > 1)
	{
		self.otherFolder = CommonAncestor(_fileBrowserItems);
		self.searchTarget = FFSearchTargetOther;
	}
	else if(NSString* parent = [self.searchFolder stringByDeletingLastPathComponent])
	{
		self.otherFolder = parent;
		self.searchTarget = FFSearchTargetOther;
	}
}

- (void)setFindString:(NSString*)aString
{
	if(_findString == aString || [_findString isEqualToString:aString])
		return;

	_findString = aString ?: @"";
	_findStringUpdated = YES;
	[self.findTextField updateIntrinsicContentSizeToEncompassString:_findString];

	if(self.findErrorString)
		[self updateFindErrorString];
}

- (void)setReplaceString:(NSString*)aString
{
	if(_replaceString == aString || [_replaceString isEqualToString:aString])
		return;

	_replaceString = aString ?: @"";
	_replaceStringUpdated = YES;
	[self.replaceTextField updateIntrinsicContentSizeToEncompassString:_replaceString];
}

- (void)setFindResultsHeight:(CGFloat)height { [NSUserDefaults.standardUserDefaults setInteger:height forKey:kUserDefaultsFindResultsHeightKey]; }
- (CGFloat)findResultsHeight                 { return [NSUserDefaults.standardUserDefaults integerForKey:kUserDefaultsFindResultsHeightKey] ?: 200; }

- (void)setRegularExpression:(BOOL)flag
{
	if(_regularExpression == flag)
		return;

	_regularExpression = flag;
	_findStringUpdated = YES;
	if(self.findErrorString)
		[self updateFindErrorString];

	_findStringFormatter.enabled    = flag;
	_replaceStringFormatter.enabled = flag;

	// Re-format current value
	if(!_findTextField.currentEditor)
	{
		_findTextField.objectValue = nil;
		_findTextField.objectValue = _findString;
	}

	if(!_replaceTextField.currentEditor)
	{
		_replaceTextField.objectValue = nil;
		_replaceTextField.objectValue = _replaceString;
	}

	[self addStylesToFieldEditor];
}

- (void)setIgnoreWhitespace:(BOOL)flag
{
	if(_ignoreWhitespace == flag)
		return;

	_ignoreWhitespace  = flag;
	_findStringUpdated = YES;
}

- (void)setFullWords:(BOOL)flag
{
	if(_fullWords == flag)
		return;

	_fullWords         = flag;
	_findStringUpdated = YES;
}

- (void)textStorageDidProcessEditing:(NSNotification*)aNotification
{
	[self addStylesToFieldEditor];
}

- (void)addStylesToFieldEditor
{
	[_findStringFormatter addStylesToString:((NSTextView*)_findTextField.currentEditor).textStorage];
	[_replaceStringFormatter addStylesToString:((NSTextView*)_replaceTextField.currentEditor).textStorage];
}

- (void)setIgnoreCase:(BOOL)flag        { if(_ignoreCase != flag) [NSUserDefaults.standardUserDefaults setObject:@(_ignoreCase = flag) forKey:kUserDefaultsFindIgnoreCase]; }
- (void)setWrapAround:(BOOL)flag        { if(_wrapAround != flag) [NSUserDefaults.standardUserDefaults setObject:@(_wrapAround = flag) forKey:kUserDefaultsFindWrapAround]; }
- (BOOL)ignoreWhitespace                { return _ignoreWhitespace && self.canIgnoreWhitespace; }
- (BOOL)canIgnoreWhitespace             { return _regularExpression == NO; }

- (BOOL)canEditGlob                     { return _searchTarget != FFSearchTargetDocument && _searchTarget != FFSearchTargetSelection; }
- (BOOL)canReplaceInDocument            { return _searchTarget == FFSearchTargetDocument || _searchTarget == FFSearchTargetSelection; }

- (NSString*)globString                 { [self commitEditing]; return _globHistoryList.head; }
- (void)setGlobString:(NSString*)aGlob  { [_globHistoryList addObject:aGlob]; }

- (void)setProjectFolder:(NSString*)aFolder
{
	if(_projectFolder != aFolder && ![_projectFolder isEqualToString:aFolder])
	{
		_projectFolder = aFolder ?: @"";
		self.globHistoryList = [[OakHistoryList alloc] initWithName:[NSString stringWithFormat:@"Find in Folder Globs.%@", _projectFolder] stackSize:10 fallbackUserDefaultsKey:kUserDefaultsDefaultFindGlobsKey];
		[self updateSearchInPopUpMenu];
	}
}

- (void)updateFolderSearchUserDefaults
{
	NSMutableDictionary* options = [NSMutableDictionary dictionary];

	if(self.searchHiddenFolders) options[@"searchHiddenFolders"] = @YES;
	if(self.searchFolderLinks)   options[@"searchFolderLinks"]   = @YES;
	if(!self.searchFileLinks)    options[@"skipFileLinks"]       = @YES;
	if(self.searchBinaryFiles)   options[@"searchBinaryFiles"]   = @YES;

	if([options count])
			[NSUserDefaults.standardUserDefaults setObject:options forKey:kUserDefaultsFolderOptionsKey];
	else	[NSUserDefaults.standardUserDefaults removeObjectForKey:kUserDefaultsFolderOptionsKey];
}

- (void)setSearchHiddenFolders:(BOOL)flag { if(_searchHiddenFolders != flag) { _searchHiddenFolders = flag; [self updateFolderSearchUserDefaults]; } }
- (void)setSearchFolderLinks:(BOOL)flag   { if(_searchFolderLinks != flag)   { _searchFolderLinks   = flag; [self updateFolderSearchUserDefaults]; } }
- (void)setSearchFileLinks:(BOOL)flag     { if(_searchFileLinks != flag)     { _searchFileLinks     = flag; [self updateFolderSearchUserDefaults]; } }
- (void)setSearchBinaryFiles:(BOOL)flag   { if(_searchBinaryFiles != flag)   { _searchBinaryFiles   = flag; [self updateFolderSearchUserDefaults]; } }

- (IBAction)toggleSearchHiddenFolders:(id)sender { self.searchHiddenFolders = !self.searchHiddenFolders; }
- (IBAction)toggleSearchFolderLinks:(id)sender   { self.searchFolderLinks   = !self.searchFolderLinks;   }
- (IBAction)toggleSearchFileLinks:(id)sender     { self.searchFileLinks     = !self.searchFileLinks;     }
- (IBAction)toggleSearchBinaryFiles:(id)sender   { self.searchBinaryFiles   = !self.searchBinaryFiles;   }

- (IBAction)takeLevelToFoldFrom:(id)sender       { [self.resultsViewController toggleCollapsedState:sender];                    }
- (IBAction)selectNextResult:(id)sender          { [self.resultsViewController selectNextResultWrapAround:self.wrapAround];     }
- (IBAction)selectPreviousResult:(id)sender      { [self.resultsViewController selectPreviousResultWrapAround:self.wrapAround]; }
- (IBAction)selectNextTab:(id)sender             { [self.resultsViewController selectNextDocument:sender];                      }
- (IBAction)selectPreviousTab:(id)sender         { [self.resultsViewController selectPreviousDocument:sender];                  }

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command
{
	if(command == @selector(moveDown:))
	{
		NSRange insertionPoint = [[textView.selectedRanges lastObject] rangeValue];
		NSRange lastNewline    = [textView.string rangeOfString:@"\n" options:NSBackwardsSearch];

		if(lastNewline.location == NSNotFound || lastNewline.location < NSMaxRange(insertionPoint))
		{
			if(control == self.findTextField)
				return [self showFindHistory:control], YES;
			else if(control == self.replaceTextField)
				return [self showReplaceHistory:control], YES;
		}
	}
	return NO;
}

- (void)controlTextDidChange:(NSNotification*)aNotification
{
	OakAutoSizingTextField* textField = [aNotification object];
	NSDictionary* userInfo = [aNotification userInfo];
	NSTextView* textView = userInfo[@"NSFieldEditor"];

	if(textView && textField)
		[textField updateIntrinsicContentSizeToEncompassString:textView.string];
}

- (BOOL)validateMenuItem:(NSMenuItem*)aMenuItem
{
	BOOL res = YES;
	if(aMenuItem.action == @selector(toggleSearchHiddenFolders:))
		[aMenuItem setState:self.searchHiddenFolders ? NSControlStateValueOn : NSControlStateValueOff];
	else if(aMenuItem.action == @selector(toggleSearchFolderLinks:))
		[aMenuItem setState:self.searchFolderLinks ? NSControlStateValueOn : NSControlStateValueOff];
	else if(aMenuItem.action == @selector(toggleSearchFileLinks:))
		[aMenuItem setState:self.searchFileLinks ? NSControlStateValueOn : NSControlStateValueOff];
	else if(aMenuItem.action == @selector(toggleSearchBinaryFiles:))
		[aMenuItem setState:self.searchBinaryFiles ? NSControlStateValueOn : NSControlStateValueOff];
	else if(aMenuItem.action == @selector(goToParentFolder:))
		res = self.searchFolder != nil || _searchTarget == FFSearchTargetFileBrowserItems && CommonAncestor(_fileBrowserItems);
	return res;
}
@end
