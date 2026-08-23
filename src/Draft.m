// The draft window: where a written document lands so it can be edited, revised
// by asking for changes, and saved or printed.

#import "MacVega.h"

static NSMutableArray<MVDraftWindow *> *sOpenDrafts(void) {
    static NSMutableArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ a = [NSMutableArray array]; });
    return a;
}

@interface MVDraftWindow () <NSWindowDelegate>
@property (strong) NSTextView *body;
@property (strong) NSTextField *reviseField;
@property (strong) NSButton *reviseBtn, *clipBtn, *saveBtn, *printBtn;
@property (strong) NSProgressIndicator *spinner;
@property (strong) NSTextField *note;
@property (strong) NSPopUpButton *formatPop;
@end

@implementation MVDraftWindow

+ (instancetype)showWithTitle:(NSString *)title text:(NSString *)text {
    MVDraftWindow *c = [[MVDraftWindow alloc] initWithWindow:nil];
    [c build];
    c.documentName = title.length ? title : @"Draft";
    c.window.title = c.documentName;
    [c setBodyText:text ?: @""];
    [sOpenDrafts() addObject:c];
    [c showWindow:nil];
    [c.window makeKeyAndOrderFront:nil];
    [c.window layoutIfNeeded];
    [c syncWidth];
    dispatch_async(dispatch_get_main_queue(), ^{ [c syncWidth]; });
    return c;
}

- (void)build {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 680, 660)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|
                  NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable
          backing:NSBackingStoreBuffered defer:NO];
    w.minSize = NSMakeSize(460, 360);
    w.delegate = self;
    w.releasedWhenClosed = NO;
    [w center];
    self.window = w;
    NSView *cv = w.contentView;

    self.clipBtn  = [NSButton buttonWithTitle:@"Copy" target:self action:@selector(doCopy:)];
    self.saveBtn  = [NSButton buttonWithTitle:@"Save…" target:self action:@selector(doSave:)];
    self.printBtn = [NSButton buttonWithTitle:@"Print…" target:self action:@selector(doPrint:)];
    self.printBtn.toolTip = @"Print, or choose “Save as PDF” in the print dialog";

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;

    self.note = [NSTextField labelWithString:@"Edit it here, or ask for changes below."];
    self.note.font = [NSFont systemFontOfSize:11];
    self.note.textColor = [NSColor secondaryLabelColor];
    self.note.lineBreakMode = NSLineBreakByTruncatingTail;

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    sv.hasVerticalScroller = YES;
    sv.borderType = NSBezelBorder;
    self.body = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 640, 500)];
    self.body.editable = YES;
    self.body.richText = NO;
    self.body.automaticQuoteSubstitutionEnabled = NO;
    self.body.automaticDashSubstitutionEnabled = NO;
    self.body.font = [NSFont systemFontOfSize:13];
    self.body.textContainerInset = NSMakeSize(10, 10);
    self.body.autoresizingMask = NSViewWidthSizable;
    self.body.minSize = NSMakeSize(0, 0);
    self.body.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.body.verticallyResizable = YES;
    self.body.horizontallyResizable = NO;
    self.body.textContainer.widthTracksTextView = YES;
    self.body.textContainer.containerSize = NSMakeSize(640, FLT_MAX);
    sv.documentView = self.body;

    self.reviseField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.reviseField.placeholderString = @"Ask for a change — “make it shorter”, “warmer tone”, “add a closing line”…";
    self.reviseField.font = [NSFont systemFontOfSize:13];
    self.reviseField.target = self;
    self.reviseField.action = @selector(doRevise:);
    self.reviseBtn = [NSButton buttonWithTitle:@"Revise" target:self action:@selector(doRevise:)];
    self.reviseBtn.keyEquivalent = @"\r";

    for (NSView *v in @[self.clipBtn, self.saveBtn, self.printBtn, self.spinner, self.note,
                        sv, self.reviseField, self.reviseBtn]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [cv addSubview:v];
    }
    for (NSView *v in @[self.clipBtn, self.saveBtn, self.printBtn, self.reviseBtn])
        [v setContentHuggingPriority:NSLayoutPriorityRequired
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.note setContentHuggingPriority:NSLayoutPriorityDefaultLow
                          forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.reviseField setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [self.clipBtn.topAnchor constraintEqualToAnchor:cv.topAnchor constant:14],
        [self.clipBtn.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:14],
        [self.saveBtn.centerYAnchor constraintEqualToAnchor:self.clipBtn.centerYAnchor],
        [self.saveBtn.leadingAnchor constraintEqualToAnchor:self.clipBtn.trailingAnchor constant:8],
        [self.printBtn.centerYAnchor constraintEqualToAnchor:self.clipBtn.centerYAnchor],
        [self.printBtn.leadingAnchor constraintEqualToAnchor:self.saveBtn.trailingAnchor constant:8],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.clipBtn.centerYAnchor],
        [self.spinner.leadingAnchor constraintEqualToAnchor:self.printBtn.trailingAnchor constant:12],
        [self.note.centerYAnchor constraintEqualToAnchor:self.clipBtn.centerYAnchor],
        [self.note.leadingAnchor constraintEqualToAnchor:self.spinner.trailingAnchor constant:8],
        [self.note.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-14],

        [sv.topAnchor constraintEqualToAnchor:self.clipBtn.bottomAnchor constant:12],
        [sv.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:14],
        [sv.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-14],

        [self.reviseField.topAnchor constraintEqualToAnchor:sv.bottomAnchor constant:10],
        [self.reviseField.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:14],
        [self.reviseField.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor constant:-14],
        [self.reviseBtn.centerYAnchor constraintEqualToAnchor:self.reviseField.centerYAnchor],
        [self.reviseBtn.leadingAnchor constraintEqualToAnchor:self.reviseField.trailingAnchor constant:8],
        [self.reviseBtn.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-14],
        [self.reviseBtn.widthAnchor constraintGreaterThanOrEqualToConstant:80],
    ]];
}

#pragma mark Text

- (NSString *)bodyText { return self.body.string ?: @""; }
- (void)setBodyText:(NSString *)t {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.body setString:t ?: @""];
        [self.body scrollRangeToVisible:NSMakeRange(0, 0)];
    });
}
- (void)appendDelta:(NSString *)d {
    if (!d.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *a = @{NSFontAttributeName: [NSFont systemFontOfSize:13],
                            NSForegroundColorAttributeName: [NSColor labelColor]};
        [self.body.textStorage appendAttributedString:
            [[NSAttributedString alloc] initWithString:d attributes:a]];
        [self.body scrollRangeToVisible:NSMakeRange(self.body.string.length, 0)];
    });
}

- (void)beginGenerating:(NSString *)what {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.spinner startAnimation:nil];
        self.note.stringValue = what ?: @"Writing…";
        self.body.editable = NO;
        self.reviseBtn.enabled = NO;
        self.reviseField.enabled = NO;
    });
}
- (void)endGenerating {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.spinner stopAnimation:nil];
        self.note.stringValue = @"Edit it here, or ask for changes below.";
        self.body.editable = YES;
        self.reviseBtn.enabled = YES;
        self.reviseField.enabled = YES;
        [self.window makeFirstResponder:self.reviseField];
    });
}

#pragma mark Actions

- (void)doCopy:(id)s {
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:[self bodyText] forType:NSPasteboardTypeString];
    self.note.stringValue = @"Copied to the clipboard.";
}

- (void)doRevise:(id)s {
    NSString *ins = [self.reviseField.stringValue
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!ins.length) return;
    self.reviseField.stringValue = @"";
    AppDelegate *app = (AppDelegate *)NSApp.delegate;
    [app reviseDraft:self instruction:ins completion:nil];
}

// Markdown, plain text and rich text cover what people actually do with a draft;
// Print is there because its dialog is also how you get a PDF on a Mac.
- (void)doSave:(id)s {
    NSSavePanel *p = [NSSavePanel savePanel];
    NSString *base = [self.documentName stringByDeletingPathExtension];
    if (!base.length) base = @"Draft";

    self.formatPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 220, 25) pullsDown:NO];
    [self.formatPop addItemsWithTitles:@[@"Markdown (.md)", @"Plain text (.txt)",
                                         @"Rich text (.rtf)", @"Word (.docx)"]];
    self.formatPop.target = self;
    self.formatPop.action = @selector(formatChanged:);
    NSView *acc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 44)];
    NSTextField *l = [NSTextField labelWithString:@"Format:"];
    l.frame = NSMakeRect(14, 12, 56, 20);
    self.formatPop.frame = NSMakeRect(72, 8, 230, 26);
    [acc addSubview:l];
    [acc addSubview:self.formatPop];
    p.accessoryView = acc;
    p.nameFieldStringValue = [base stringByAppendingPathExtension:@"md"];
    p.canCreateDirectories = YES;

    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK || !p.URL) return;
        NSError *e = nil;
        if (![self writeTo:p.URL format:self.formatPop.indexOfSelectedItem error:&e]) {
            NSAlert *a = [NSAlert new];
            a.messageText = @"Could not save the draft";
            a.informativeText = e.localizedDescription ?: @"unknown error";
            [a beginSheetModalForWindow:self.window completionHandler:nil];
            return;
        }
        self.documentName = p.URL.lastPathComponent;
        self.window.title = self.documentName;
        self.note.stringValue = [NSString stringWithFormat:@"Saved to %@.", p.URL.path];
    }];
}

- (void)formatChanged:(id)s {
    NSArray *ext = @[@"md", @"txt", @"rtf", @"docx"];
    NSSavePanel *p = (NSSavePanel *)self.formatPop.window;
    if (![p isKindOfClass:[NSSavePanel class]]) return;
    NSString *base = [p.nameFieldStringValue stringByDeletingPathExtension];
    p.nameFieldStringValue = [base stringByAppendingPathExtension:
        ext[MAX(0, self.formatPop.indexOfSelectedItem)]];
}

- (BOOL)writeTo:(NSURL *)url format:(NSInteger)fmt error:(NSError **)err {
    NSString *text = [self bodyText];
    if (fmt <= 1)   // Markdown and plain text are the same bytes; the model writes Markdown
        return [text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:err];

    NSAttributedString *rich = MVRenderMarkdown(text, 12);
    NSRange all = NSMakeRange(0, rich.length);
    NSString *type = (fmt == 2) ? NSRTFTextDocumentType : NSOfficeOpenXMLTextDocumentType;
    NSData *d = [rich dataFromRange:all
                 documentAttributes:@{NSDocumentTypeDocumentAttribute: type}
                              error:err];
    if (!d) return NO;
    return [d writeToURL:url options:NSDataWritingAtomic error:err];
}

- (void)doPrint:(id)s {
    NSPrintInfo *pi = [[NSPrintInfo sharedPrintInfo] copy];
    pi.horizontalPagination = NSPrintingPaginationModeFit;
    pi.verticalPagination = NSPrintingPaginationModeAutomatic;
    pi.leftMargin = 60; pi.rightMargin = 60; pi.topMargin = 60; pi.bottomMargin = 60;
    CGFloat w = pi.paperSize.width - pi.leftMargin - pi.rightMargin;

    NSTextView *pv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, w, pi.paperSize.height)];
    [pv.textStorage setAttributedString:MVRenderMarkdown([self bodyText], 11)];
    pv.textContainer.containerSize = NSMakeSize(w, FLT_MAX);
    pv.textContainer.widthTracksTextView = YES;
    pv.verticallyResizable = YES;
    [pv sizeToFit];

    NSPrintOperation *op = [NSPrintOperation printOperationWithView:pv printInfo:pi];
    op.jobTitle = self.documentName;
    [op runOperationModalForWindow:self.window delegate:nil didRunSelector:NULL contextInfo:NULL];
}

// Same trap as the transcript: a text view built before layout keeps a frame
// wider than the scroll view, and then nothing wraps.
- (void)syncWidth {
    NSClipView *clip = self.body.enclosingScrollView.contentView;
    CGFloat w = NSWidth(clip.bounds);
    if (w < 1) return;
    NSRect f = self.body.frame;
    f.size.width = w;
    self.body.frame = f;
    self.body.textContainer.containerSize =
        NSMakeSize(w - 2 * self.body.textContainerInset.width, FLT_MAX);
}
- (void)windowDidResize:(NSNotification *)n { [self syncWidth]; }
- (void)windowWillClose:(NSNotification *)n { [sOpenDrafts() removeObject:self]; }
@end
