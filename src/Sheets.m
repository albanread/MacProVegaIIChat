// The two sheets: Settings, and "write me a document".
//
// Both are hand-built rather than loaded from a nib, for the same reason as the
// rest of the app — one clang invocation, no Xcode.

#import "MacVega.h"

#pragma mark - small layout helpers

static NSTextField *MVLabel(NSString *s, BOOL secondary) {
    NSTextField *l = [NSTextField labelWithString:s];
    l.font = [NSFont systemFontOfSize:secondary ? 11 : 13];
    if (secondary) l.textColor = [NSColor secondaryLabelColor];
    l.lineBreakMode = NSLineBreakByWordWrapping;
    l.maximumNumberOfLines = 3;
    return l;
}

static NSScrollView *MVTextBox(NSTextView **out, CGFloat height, NSString *placeholder) {
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    sv.hasVerticalScroller = YES;
    sv.borderType = NSBezelBorder;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, height)];
    tv.font = [NSFont systemFontOfSize:12];
    tv.richText = NO;
    tv.automaticQuoteSubstitutionEnabled = NO;
    tv.textContainerInset = NSMakeSize(4, 4);
    tv.minSize = NSMakeSize(0, 0);
    tv.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    tv.verticallyResizable = YES;
    tv.horizontallyResizable = NO;
    tv.textContainer.widthTracksTextView = YES;
    sv.documentView = tv;
    [sv.heightAnchor constraintEqualToConstant:height].active = YES;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    (void)placeholder;
    if (out) *out = tv;
    return sv;
}

// A vertical stack of rows inside a plain sheet window, with OK/Cancel at the foot.
static NSWindow *MVSheet(NSArray<NSView *> *rows, NSView *okBtn, NSView *cancelBtn, CGFloat width) {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, 100)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSView *cv = w.contentView;

    NSStackView *buttons = [NSStackView stackViewWithViews:@[cancelBtn, okBtn]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 10;

    NSStackView *stack = [NSStackView stackViewWithViews:rows];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:stack];
    [cv addSubview:buttons];

    NSMutableArray *cs = [@[
        [stack.topAnchor constraintEqualToAnchor:cv.topAnchor constant:20],
        [stack.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-20],
        [buttons.topAnchor constraintEqualToAnchor:stack.bottomAnchor constant:18],
        [buttons.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-20],
        [buttons.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor constant:-18],
        [cv.widthAnchor constraintEqualToConstant:width],
    ] mutableCopy];
    for (NSView *r in rows)
        [cs addObject:[r.widthAnchor constraintEqualToAnchor:stack.widthAnchor]];
    [NSLayoutConstraint activateConstraints:cs];
    return w;
}

#pragma mark - Settings

// Nothing in here is described in tokens, degrees or sampler names. A setting
// nobody can picture is a setting nobody touches.

@interface MVSettingsSheet : NSObject
@property (strong) NSWindow *sheet;
@property (strong) NSTextView *systemPrompt;
@property (strong) NSPopUpButton *ctxPop, *replyPop;
@property (strong) NSSegmentedControl *stylePick, *sizePick;
@property (strong) NSButton *thinkBox, *showThinkBox, *autoStartBox;
@end

static NSArray *MVCtxChoices(void)   { return @[@4096, @8192, @16384, @32768, @65536]; }
static NSArray *MVReplyChoices(void) { return @[@512, @1024, @2048, @4096, @8192]; }
static NSArray *MVStyleTemps(void)   { return @[@0.2, @0.7, @1.1]; }
static NSArray *MVTextSizes(void)    { return @[@12, @13, @16]; }

static NSInteger MVNearest(NSArray *choices, double v) {
    NSInteger best = 0; double d = 1e9;
    for (NSUInteger i = 0; i < choices.count; i++) {
        double c = fabs([choices[i] doubleValue] - v);
        if (c < d) { d = c; best = (NSInteger) i; }
    }
    return best;
}

// label in the left column, control in the right, explanations across both
static NSGridView *MVGrid(void) {
    NSGridView *g = [NSGridView gridViewWithNumberOfColumns:2 rows:0];
    g.columnSpacing = 14;
    g.rowSpacing = 8;
    [g columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [g columnAtIndex:0].width = 150;
    g.translatesAutoresizingMaskIntoConstraints = NO;
    return g;
}
static void MVRow(NSGridView *g, NSString *label, NSView *control) {
    [g addRowWithViews:@[MVLabel(label ?: @"", NO), control]];
}
static void MVNote(NSGridView *g, NSString *text) {
    NSTextField *l = MVLabel(text, YES);
    l.maximumNumberOfLines = 5;
    l.preferredMaxLayoutWidth = 500;
    NSGridRow *r = [g addRowWithViews:@[l]];
    [r mergeCellsInRange:NSMakeRange(0, 2)];
    [r cellAtIndex:0].xPlacement = NSGridCellPlacementLeading;
    r.bottomPadding = 8;
}

@implementation MVSettingsSheet

- (void)presentOver:(NSWindow *)parent {
    NSButton *ok = [NSButton buttonWithTitle:@"Save" target:self action:@selector(save:)];
    ok.keyEquivalent = @"\r";
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\033";

    NSTextView *spv = nil;
    NSScrollView *sp = MVTextBox(&spv, 62, nil);
    self.systemPrompt = spv;
    self.systemPrompt.string = MVSystemPrompt();

    self.ctxPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSNumber *n in MVCtxChoices())
        [self.ctxPop addItemWithTitle:[NSString stringWithFormat:@"About %ld pages of text  (%ldk)",
            (long) MAX(1, lround(n.integerValue / 650.0)), (long)(n.integerValue / 1024)]];
    [self.ctxPop selectItemAtIndex:MVNearest(MVCtxChoices(), MVContextTokens())];

    NSArray *replyNames = @[@"Brief — a paragraph or two",
                            @"Short — about half a page",
                            @"Normal — about a page",
                            @"Long — two or three pages",
                            @"As long as it likes"];
    self.replyPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.replyPop addItemsWithTitles:replyNames];
    [self.replyPop selectItemAtIndex:MVNearest(MVReplyChoices(), MVMaxReplyTokens())];

    self.stylePick = [NSSegmentedControl segmentedControlWithLabels:@[@"Precise", @"Balanced", @"Inventive"]
                                                       trackingMode:NSSegmentSwitchTrackingSelectOne
                                                             target:nil action:nil];
    self.stylePick.selectedSegment = MVNearest(MVStyleTemps(), MVTemperature());

    self.sizePick = [NSSegmentedControl segmentedControlWithLabels:@[@"Small", @"Normal", @"Large"]
                                                     trackingMode:NSSegmentSwitchTrackingSelectOne
                                                           target:nil action:nil];
    self.sizePick.selectedSegment = MVNearest(MVTextSizes(), MVTextSize());

    self.thinkBox = [NSButton checkboxWithTitle:@"Let it think before it answers" target:nil action:nil];
    self.thinkBox.state = MVThinkingEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    self.showThinkBox = [NSButton checkboxWithTitle:@"Leave the thinking on screen" target:nil action:nil];
    self.showThinkBox.state = MVShowThinking() ? NSControlStateValueOn : NSControlStateValueOff;
    self.autoStartBox = [NSButton checkboxWithTitle:@"Start the model when I open the app" target:nil action:nil];
    self.autoStartBox.state = MVAutoStart() ? NSControlStateValueOn : NSControlStateValueOff;

    NSGridView *g = MVGrid();
    MVRow(g, @"Standing instructions", sp);
    MVNote(g, @"Sent ahead of every conversation, so you do not have to keep repeating "
              @"yourself. “Answer in British English.” “You are a careful technical editor.” "
              @"Leave it empty if you would rather not.");

    MVRow(g, @"Keeps in mind", self.ctxPop);
    MVNote(g, @"How much of one conversation it can hold at once — your messages, its replies "
              @"and any document you have open, all together. More uses more of the graphics "
              @"card, and takes effect next time you press Start.");

    MVRow(g, @"Answers up to", self.replyPop);
    MVNote(g, @"A ceiling, not a target. Most answers are far shorter.");

    MVRow(g, @"Style", self.stylePick);
    MVNote(g, @"Precise stays close to what it was asked. Inventive takes more liberties — "
              @"better for a first draft, worse for facts.");

    MVRow(g, @"", self.thinkBox);
    MVNote(g, @"It works the problem through first, which helps on hard questions and wastes "
              @"time on easy ones. Reading and drafting never think — those are mechanical jobs.");

    MVRow(g, @"", self.showThinkBox);
    MVRow(g, @"", self.autoStartBox);
    MVRow(g, @"Text size", self.sizePick);
    MVNote(g, @"Applies to whatever is said next.");

    self.sheet = MVSheet(@[g], ok, cancel, 560);
    [parent beginSheet:self.sheet completionHandler:^(NSModalResponse r) {}];
}

- (void)close { [self.sheet.sheetParent endSheet:self.sheet]; }
- (void)cancel:(id)s { [self close]; }
- (void)save:(id)s {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSInteger wasCtx = MVContextTokens();
    [d setObject:self.systemPrompt.string ?: @"" forKey:MVPrefSystemPrompt];
    [d setDouble:[MVStyleTemps()[MAX(0, self.stylePick.selectedSegment)] doubleValue] forKey:MVPrefTemperature];
    [d setInteger:[MVCtxChoices()[MAX(0, self.ctxPop.indexOfSelectedItem)] integerValue] forKey:MVPrefContextTokens];
    [d setInteger:[MVReplyChoices()[MAX(0, self.replyPop.indexOfSelectedItem)] integerValue] forKey:MVPrefMaxReplyTokens];
    [d setDouble:[MVTextSizes()[MAX(0, self.sizePick.selectedSegment)] doubleValue] forKey:MVPrefTextSize];
    [d setBool:(self.thinkBox.state == NSControlStateValueOn) forKey:MVPrefThinking];
    [d setBool:(self.showThinkBox.state == NSControlStateValueOn) forKey:MVPrefShowThinking];
    [d setBool:(self.autoStartBox.state == NSControlStateValueOn) forKey:MVPrefAutoStart];

    AppDelegate *app = (AppDelegate *)NSApp.delegate;
    if ([app engineRunning] && MVContextTokens() != wasCtx)
        [app say:@"system" text:@"Saved. The new memory size takes effect once you press Put "
                                @"Away and Start again."];
    [self close];
}
@end

#pragma mark - "Write me a document"

@interface MVDraftSheet : NSObject
@property (strong) NSWindow *sheet;
@property (strong) NSPopUpButton *kindPop, *tonePop, *lengthPop;
@property (strong) NSTextView *brief;
@property (strong) NSButton *useDoc;
@end

@implementation MVDraftSheet

- (void)presentOver:(NSWindow *)parent {
    AppDelegate *app = (AppDelegate *)NSApp.delegate;

    NSButton *ok = [NSButton buttonWithTitle:@"Write it" target:self action:@selector(go:)];
    ok.keyEquivalent = @"\r";
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\033";

    self.kindPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.kindPop addItemsWithTitles:[MVDraftSpec kinds]];
    self.tonePop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.tonePop addItemsWithTitles:[MVDraftSpec tones]];
    self.lengthPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.lengthPop addItemsWithTitles:[MVDraftSpec lengths]];
    [self.lengthPop selectItemAtIndex:1];

    NSStackView *row = [NSStackView stackViewWithViews:@[self.kindPop, self.tonePop, self.lengthPop]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    row.distribution = NSStackViewDistributionFillEqually;

    NSTextView *briefView = nil;
    NSScrollView *briefBox = MVTextBox(&briefView, 110, nil);
    self.brief = briefView;

    self.useDoc = [NSButton checkboxWithTitle:
        app.document ? [NSString stringWithFormat:@"Use “%@” as source material", app.document.name]
                     : @"Use the attached document as source material"
                                       target:nil action:nil];
    self.useDoc.enabled = (app.document != nil);
    self.useDoc.state = app.document ? NSControlStateValueOn : NSControlStateValueOff;

    self.sheet = MVSheet(@[
        MVLabel(@"What should it be?", NO),
        row,
        MVLabel(@"What is it for?", NO),
        MVLabel(@"Say who it is for and what it needs to do. The more you put here, the less "
                @"you will have to fix afterwards.", YES),
        briefBox,
        self.useDoc,
    ], ok, cancel, 520);

    [parent beginSheet:self.sheet completionHandler:^(NSModalResponse r) {}];
    [self.sheet makeFirstResponder:self.brief];
}

- (void)close { [self.sheet.sheetParent endSheet:self.sheet]; }
- (void)cancel:(id)s { [self close]; }
- (void)go:(id)s {
    AppDelegate *app = (AppDelegate *)NSApp.delegate;
    NSString *brief = [self.brief.string stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!brief.length) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"What should it say?";
        a.informativeText = @"Give the model something to go on — even one line helps.";
        [a beginSheetModalForWindow:self.sheet completionHandler:nil];
        return;
    }
    MVDraftSpec *spec = [MVDraftSpec new];
    spec.kind = self.kindPop.titleOfSelectedItem;
    spec.tone = self.tonePop.titleOfSelectedItem;
    spec.length = self.lengthPop.titleOfSelectedItem;
    spec.brief = brief;
    if (self.useDoc.state == NSControlStateValueOn && app.document) {
        // Only as much of the document as will fit alongside a reply.
        NSString *t = app.document.text;
        NSUInteger cap = (NSUInteger)((MVContextTokens() - 4000) * 3 * 0.7);
        spec.source = (t.length > cap) ? [t substringToIndex:cap] : t;
    }
    [self close];
    [app generateDraft:spec completion:nil];
}
@end

#pragma mark - Hooks used by the menu

@implementation AppDelegate (Sheets)

- (void)showSettings:(id)sender {
    static MVSettingsSheet *keep;
    keep = [MVSettingsSheet new];
    [keep presentOver:self.win];
}

- (void)newDraft:(id)sender {
    static MVDraftSheet *keep;
    keep = [MVDraftSheet new];
    [keep presentOver:self.win];
}
@end
