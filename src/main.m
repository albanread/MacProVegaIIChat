// MacVegaII Chat — a local chat, document and drafting app for the Mac Pro (2019)
// with a Radeon Pro Vega II.
//
// llama.cpp (the IntelMacLlamaCpp fork) is linked in; see Llama.mm. This file is
// the window, the model catalogue and the document work. It picks the Metal
// device explicitly, which matters on a Mac Pro where the system default is
// often the weaker card driving the display.

#import "MacVega.h"
#import <Metal/Metal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const NSInteger kMetal3 = 5001;

#pragma mark - Model catalogue

static double MVMeasuredTPS(NSString *file);
static void   MVRecordTPS(NSString *file, double tps);

@interface ModelSpec : NSObject
@property (copy) NSString *name;     // "Qwen3 8B"
@property (copy) NSString *blurb;    // what it is like to use, in plain words
@property (copy) NSString *file;
@property (copy) NSString *url;      // nil for a file the user chose themselves
@property (assign) double gib;       // download size
@property (assign) double needGiB;   // graphics memory for a comfortable fit
@property (assign) double tps;       // measured on a Vega II; 0 means nobody has timed it
- (NSString *)menuTitle;
- (double)expectedTPS;               // your own rate if there is one, else the table
- (BOOL)tpsIsYourOwn;
@end
@implementation ModelSpec
+ (instancetype)n:(NSString *)n b:(NSString *)b f:(NSString *)f u:(NSString *)u
                g:(double)g v:(double)v t:(double)t {
    ModelSpec *m = [ModelSpec new];
    m.name = n; m.blurb = b; m.file = f; m.url = u; m.gib = g; m.needGiB = v; m.tps = t;
    return m;
}
- (NSString *)menuTitle {
    if (!self.url) return [NSString stringWithFormat:@"%@  ·  your own file", self.name];
    return [NSString stringWithFormat:@"%@  ·  %.1f GB  ·  %@", self.name, self.gib, self.blurb];
}
// The rate this model actually managed here, falling back to what was measured on
// the machine this app was built for.
- (double)expectedTPS {
    double mine = MVMeasuredTPS(self.file);
    return mine > 0 ? mine : self.tps;
}
- (BOOL)tpsIsYourOwn { return MVMeasuredTPS(self.file) > 0; }
@end

// Speeds are what was actually measured on a Radeon Pro Vega II, not arithmetic.
// Where nobody has timed a model the figure is left at zero and the app says so
// rather than inventing one. Once you have run a model yourself, your own rate
// replaces the table.
static NSArray<ModelSpec *> *Catalogue(void) {
    NSMutableArray *a = [@[
        [ModelSpec n:@"Llama 3.2 3B"
                   b:@"the quickest here, and the smallest download"
                   f:@"Llama-3.2-3B-Instruct-Q5_K_M.gguf"
                   u:@"https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q5_K_M.gguf"
                   g:2.3 v:4.0 t:54.4],
        [ModelSpec n:@"Qwen3 4B"
                   b:@"small and quick, good for chat and short documents"
                   f:@"Qwen3-4B-Q4_K_M.gguf"
                   u:@"https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf"
                   g:2.5 v:4.0 t:0],
        [ModelSpec n:@"Qwen3 8B"
                   b:@"a good all-rounder, and the safe first choice"
                   f:@"Qwen3-8B-Q4_K_M.gguf"
                   u:@"https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf"
                   g:5.0 v:7.0 t:46.9],
        [ModelSpec n:@"Qwen3 14B"
                   b:@"better at writing and reviewing than the 8B"
                   f:@"Qwen3-14B-Q4_K_M.gguf"
                   u:@"https://huggingface.co/Qwen/Qwen3-14B-GGUF/resolve/main/Qwen3-14B-Q4_K_M.gguf"
                   g:9.0 v:12.0 t:0],
        [ModelSpec n:@"Gemma 4 26B-A4B"
                   b:@"quick for its size; a little looser than the Qwen 30B"
                   f:@"gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf"
                   u:@"https://huggingface.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF/resolve/main/gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf"
                   g:14.2 v:17.0 t:0],
        [ModelSpec n:@"Qwen3 30B-A3B"
                   b:@"the best of these AND almost the fastest — start here if it fits"
                   f:@"Qwen3-30B-A3B-Q4_K_M.gguf"
                   u:@"https://huggingface.co/Qwen/Qwen3-30B-A3B-GGUF/resolve/main/Qwen3-30B-A3B-Q4_K_M.gguf"
                   g:18.6 v:22.0 t:51.9],
        [ModelSpec n:@"Qwen3 32B"
                   b:@"thorough, but far slower than the 30B above"
                   f:@"Qwen3-32B-Q4_K_M.gguf"
                   u:@"https://huggingface.co/Qwen/Qwen3-32B-GGUF/resolve/main/Qwen3-32B-Q4_K_M.gguf"
                   g:19.8 v:24.0 t:0],
    ] mutableCopy];
    // Plenty of Mac Pro owners already have a shelf of GGUF files and no wish to
    // download another. Whatever they last picked stays in the list.
    NSString *custom = [[NSUserDefaults standardUserDefaults] stringForKey:MVPrefCustomModelPath];
    if (custom.length && [[NSFileManager defaultManager] fileExistsAtPath:custom]) {
        [a addObject:[ModelSpec n:custom.lastPathComponent b:@"" f:custom u:nil g:0 v:0 t:0]];
    }
    return a;
}

// The app times every reply anyway, so once you have used a model your own rate
// is better evidence than the table above — and it is the only figure that means
// anything on a card other than a Vega II.
static NSString *const MVPrefMeasured = @"MeasuredTokensPerSecond";

static double MVMeasuredTPS(NSString *file) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:MVPrefMeasured];
    return [d[file.lastPathComponent] doubleValue];
}
static void MVRecordTPS(NSString *file, double tps) {
    if (tps <= 0 || !file.length) return;
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *d = [([u dictionaryForKey:MVPrefMeasured] ?: @{}) mutableCopy];
    double was = [d[file.lastPathComponent] doubleValue];
    // ease towards the new reading so one odd reply does not redefine the model
    d[file.lastPathComponent] = @(was > 0 ? was * 0.7 + tps * 0.3 : tps);
    [u setObject:d forKey:MVPrefMeasured];
}

#pragma mark - GPU selection

// Returns the index into MTLCopyAllDevices() of the most capable GPU, and reports its
// name/VRAM. On a Mac Pro the system default is the GPU driving the display, which is
// often NOT the compute card — hence the explicit choice.
static NSInteger BestMetalDevice(NSString **nameOut, double *vramGiBOut, BOOL *metal3Out) {
    NSArray<id<MTLDevice>> *devs = MTLCopyAllDevices();
    NSInteger best = -1; double bestScore = -1;
    for (NSUInteger i = 0; i < devs.count; i++) {
        id<MTLDevice> d = devs[i];
        double vram = (double) d.recommendedMaxWorkingSetSize / (1024.0*1024.0*1024.0);
        BOOL metal3 = [d supportsFamily:(MTLGPUFamily) kMetal3];
        // llama.cpp's Metal backend needs simdgroup reduction, which on these cards
        // comes from Metal 3. A Metal-2-only GPU cannot run the backend at all.
        double score = vram + (metal3 ? 1000.0 : 0.0);
        if (score > bestScore) { bestScore = score; best = (NSInteger) i;
            if (nameOut) *nameOut = [d name];
            if (vramGiBOut) *vramGiBOut = vram;
            if (metal3Out) *metal3Out = metal3; }
    }
    return best;
}

#pragma mark - Window screenshot

BOOL MVWriteWindowPNG(NSWindow *win, NSString *path, NSError **err) {
    __block BOOL ok = NO;
    __block NSError *e = nil;
    void (^shoot)(void) = ^{
        NSView *v = win.contentView;
        NSRect b = v.bounds;
        if (b.size.width < 1 || b.size.height < 1) {
            e = [NSError errorWithDomain:@"MacVegaIIChat" code:20 userInfo:@{
                NSLocalizedDescriptionKey: @"the window has no size to capture"}];
            return;
        }
        [v displayIfNeeded];
        NSBitmapImageRep *shot = [v bitmapImageRepForCachingDisplayInRect:b];
        [v cacheDisplayInRect:b toBitmapImageRep:shot];

        // The content view draws no background of its own — the window frame does,
        // and that is outside what cacheDisplayInRect: gives us. Without painting
        // it first, a dark-mode capture is white text on nothing.
        NSBitmapImageRep *out = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
                          pixelsWide:shot.pixelsWide
                          pixelsHigh:shot.pixelsHigh
                       bitsPerSample:8
                     samplesPerPixel:4
                            hasAlpha:YES
                            isPlanar:NO
                      colorSpaceName:NSDeviceRGBColorSpace
                         bytesPerRow:0
                        bitsPerPixel:0];
        out.size = b.size;      // keeps the backing scale, so Retina stays Retina

        NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:out];
        void (^compose)(void) = ^{
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext = ctx;
            [(win.backgroundColor ?: [NSColor windowBackgroundColor]) setFill];
            NSRectFill(b);
            [shot drawInRect:b];
            [NSGraphicsContext restoreGraphicsState];
        };
        // Resolve windowBackgroundColor against the window's own appearance, not
        // whatever happens to be current.
        [win.effectiveAppearance performAsCurrentDrawingAppearance:compose];

        NSData *png = [out representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (!png) {
            e = [NSError errorWithDomain:@"MacVegaIIChat" code:21 userInfo:@{
                NSLocalizedDescriptionKey: @"could not encode the window as PNG"}];
            return;
        }
        ok = [png writeToFile:path.stringByExpandingTildeInPath
                      options:NSDataWritingAtomic error:&e];
    };
    if ([NSThread isMainThread]) shoot();
    else dispatch_sync(dispatch_get_main_queue(), shoot);
    if (!ok && err) *err = e;
    return ok;
}

#pragma mark - Drop target

@interface MVDropView : NSView
@property (assign) BOOL dropping;
@end

@implementation MVDropView
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f]))
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    return self;
}
- (NSArray<NSURL *> *)urlsFrom:(id<NSDraggingInfo>)s {
    return [s.draggingPasteboard readObjectsForClasses:@[[NSURL class]]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)s {
    NSArray<NSURL *> *u = [self urlsFrom:s];
    if (u.count != 1 || !MVCanReadDocument(u[0])) return NSDragOperationNone;
    self.dropping = YES; [self setNeedsDisplay:YES];
    return NSDragOperationCopy;
}
- (void)draggingExited:(id<NSDraggingInfo>)s { self.dropping = NO; [self setNeedsDisplay:YES]; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)s {
    self.dropping = NO; [self setNeedsDisplay:YES];
    NSArray<NSURL *> *u = [self urlsFrom:s];
    if (u.count != 1) return NO;
    AppDelegate *app = (AppDelegate *)NSApp.delegate;
    NSString *err = nil;
    if (![app attachDocumentAtPath:u[0].path error:&err]) {
        [app say:@"system" text:[NSString stringWithFormat:@"Could not read %@ — %@",
                                 u[0].lastPathComponent, err]];
        return NO;
    }
    return YES;
}
- (void)drawRect:(NSRect)r {
    [super drawRect:r];
    if (!self.dropping) return;
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 6, 6)
                                                      xRadius:10 yRadius:10];
    p.lineWidth = 3;
    CGFloat pattern[2] = {8, 6};
    [p setLineDash:pattern count:2 phase:0];
    [[NSColor controlAccentColor] setStroke];
    [p stroke];
}
@end

#pragma mark - App

@interface AppDelegate () <NSTextViewDelegate, NSWindowDelegate>
@property (strong) NSStackView *root;
@property (strong) NSView *attachBar;
@property (strong) NSTextField *attachLabel;
@property (strong) NSPopUpButton *reviewPop;
@property (strong) NSScrollView *inputScroll;
@property (strong) NSLayoutConstraint *inputHeight;
@property (strong) NSButton *attachBtn;
@property (strong) NSURLSession *dl;
@property (strong) NSMutableString *pending;
@property (assign) NSInteger gpuIndex;
@property (assign) BOOL cancelled;
@property (assign) BOOL ready;
@property (assign) NSInteger chooseFileIndex;
@property (assign) BOOL warmedUp;
@property (copy)   NSString *lastTimingLine;
@property (strong) NSWindow *settingsSheet;
@property (strong) NSWindow *draftSheet;
@end

@implementation AppDelegate

#pragma mark Paths and models

- (NSString *)supportDir {
    NSString *d = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    d = [d stringByAppendingPathComponent:@"MacVegaIIChat/models"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
- (ModelSpec *)selectedModel {
    NSArray *c = Catalogue();
    NSInteger i = self.modelPop.indexOfSelectedItem;
    return c[MAX(0, MIN((NSInteger)c.count - 1, i))];
}
- (BOOL)chooseFileItemSelected {
    return self.chooseFileIndex > 0 && self.modelPop.indexOfSelectedItem == self.chooseFileIndex;
}
- (NSString *)modelPath:(ModelSpec *)m {
    if (!m.url) return m.file;      // a file the user chose: already an absolute path
    return [[self supportDir] stringByAppendingPathComponent:m.file];
}
- (BOOL)modelPresent:(ModelSpec *)m {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self modelPath:m]];
}
- (NSString *)currentModelName { return [self selectedModel].file.lastPathComponent; }
- (BOOL)selectModelNamed:(NSString *)name {
    NSArray<ModelSpec *> *c = Catalogue();
    for (NSUInteger i = 0; i < c.count; i++) {
        if ([c[i].file.lastPathComponent isEqualToString:name] ||
            [c[i].name localizedCaseInsensitiveContainsString:name]) {
            [self.modelPop selectItemAtIndex:i];
            [self modelChanged:nil];
            return YES;
        }
    }
    return NO;
}
- (void)rebuildModelMenu {
    NSString *was = self.modelPop.titleOfSelectedItem;
    [self.modelPop removeAllItems];
    NSArray<ModelSpec *> *c = Catalogue();
    for (ModelSpec *m in c) {
        [self.modelPop addItemWithTitle:[m menuTitle]];
        // a tick beside the ones already on this Mac, so nobody re-downloads 19 GB
        if ([self modelPresent:m])
            [self.modelPop itemAtIndex:self.modelPop.numberOfItems - 1].image =
                [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill" accessibilityDescription:@"already downloaded"];
    }
    [self.modelPop.menu addItem:[NSMenuItem separatorItem]];
    [self.modelPop addItemWithTitle:@"Use a model file I already have…  (untested)"];
    self.chooseFileIndex = self.modelPop.numberOfItems - 1;
    if (was) [self.modelPop selectItemWithTitle:was];
    if (self.modelPop.indexOfSelectedItem < 0 ||
        self.modelPop.indexOfSelectedItem >= (NSInteger)c.count) [self.modelPop selectItemAtIndex:0];
}

#pragma mark UI

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    // Test hook: MV_APPEARANCE=dark builds the whole interface dark from the
    // start, which is how a user with dark mode set meets it. Switching a live
    // window instead only half-repaints, so this is the honest way to check it.
    const char *look = getenv("MV_APPEARANCE");
    if (look) {
        NSString *w = [@(look) lowercaseString];
        if ([w hasPrefix:@"d"]) NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        else if ([w hasPrefix:@"l"]) NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    }

    // Two copies of this app means two engines and twice the VRAM. Hand over to the
    // one that is already up rather than quietly making the machine unusable.
    NSArray<NSRunningApplication *> *twins = [NSRunningApplication
        runningApplicationsWithBundleIdentifier:[NSBundle mainBundle].bundleIdentifier];
    if (twins.count > 1) {
        for (NSRunningApplication *a in twins)
            if (![a isEqual:[NSRunningApplication currentApplication]])
                [a activateWithOptions:NSApplicationActivateAllWindows];
        [NSApp terminate:nil];
        return;
    }
    self.history = [NSMutableArray array];
    NSString *gname = nil; double gvram = 0; BOOL gm3 = NO;
    self.gpuIndex = BestMetalDevice(&gname, &gvram, &gm3);
    self.gpuName = gname; self.gpuVRAM = gvram; self.gpuMetal3 = gm3;

    NSRect r = NSMakeRect(0, 0, 820, 660);
    self.win = [[NSWindow alloc] initWithContentRect:r
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.win.title = @"MacVegaII Chat (for Mac Pro)";
    self.win.minSize = NSMakeSize(620, 460);
    [self.win center];
    self.win.contentView = [[MVDropView alloc] initWithFrame:r];
    NSView *cv = self.win.contentView;

    // --- top row -----------------------------------------------------------
    self.modelPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.modelPop.target = self; self.modelPop.action = @selector(modelChanged:);
    [self rebuildModelMenu];

    self.actionBtn = [NSButton buttonWithTitle:@"Download" target:self action:@selector(action:)];
    self.actionBtn.keyEquivalent = @"\r";
    self.resetBtn = [NSButton buttonWithTitle:@"New Chat" target:self action:@selector(startNewChat:)];
    self.resetBtn.toolTip = @"Forget the conversation so far and start fresh";

    NSStackView *top = [NSStackView stackViewWithViews:@[self.modelPop, self.resetBtn, self.actionBtn]];
    top.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    top.spacing = 8;
    [self.modelPop setContentHuggingPriority:NSLayoutPriorityDefaultLow
                              forOrientation:NSLayoutConstraintOrientationHorizontal];

    // --- progress and status ----------------------------------------------
    self.prog = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.prog.style = NSProgressIndicatorStyleBar; self.prog.indeterminate = NO;
    self.prog.minValue = 0; self.prog.maxValue = 1; self.prog.hidden = YES;

    self.status = [NSTextField labelWithString:@""];
    self.status.textColor = [NSColor secondaryLabelColor];
    self.status.font = [NSFont systemFontOfSize:11];
    self.status.lineBreakMode = NSLineBreakByTruncatingTail;

    // --- attachment bar ----------------------------------------------------
    [self buildAttachBar];

    // --- transcript --------------------------------------------------------
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    sv.hasVerticalScroller = YES; sv.borderType = NSBezelBorder;
    self.transcript = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 780, 400)];
    self.transcript.editable = NO; self.transcript.richText = YES;
    self.transcript.font = [NSFont systemFontOfSize:MVTextSize()];
    self.transcript.textContainerInset = NSMakeSize(8, 8);
    self.transcript.autoresizingMask = NSViewWidthSizable;
    self.transcript.minSize = NSMakeSize(0, 0);
    self.transcript.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.transcript.verticallyResizable = YES;
    self.transcript.horizontallyResizable = NO;
    self.transcript.textContainer.widthTracksTextView = YES;
    sv.documentView = self.transcript;
    [sv setContentHuggingPriority:NSLayoutPriorityDefaultLow
                   forOrientation:NSLayoutConstraintOrientationVertical];

    // --- input row ---------------------------------------------------------
    self.inputScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.inputScroll.hasVerticalScroller = YES;
    self.inputScroll.borderType = NSBezelBorder;
    self.input = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 600, 30)];
    self.input.font = [NSFont systemFontOfSize:13];
    self.input.delegate = self;
    self.input.editable = NO;
    self.input.richText = NO;
    self.input.automaticQuoteSubstitutionEnabled = NO;
    self.input.textContainerInset = NSMakeSize(4, 5);
    self.input.minSize = NSMakeSize(0, 0);
    self.input.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.input.verticallyResizable = YES;
    self.input.horizontallyResizable = NO;
    self.input.textContainer.widthTracksTextView = YES;
    self.inputScroll.documentView = self.input;
    self.inputHeight = [self.inputScroll.heightAnchor constraintEqualToConstant:38];
    self.inputHeight.active = YES;

    self.attachBtn = [NSButton buttonWithTitle:@"Attach…" target:self action:@selector(openDocument:)];
    self.attachBtn.toolTip = @"Give the model a document to work from — or just drag one onto this window";
    self.sendBtn = [NSButton buttonWithTitle:@"Send" target:self action:@selector(send:)];
    self.sendBtn.enabled = NO;
    self.stopBtn = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(stopGen:)];
    self.stopBtn.enabled = NO;

    NSStackView *bottom = [NSStackView stackViewWithViews:
        @[self.inputScroll, self.attachBtn, self.sendBtn, self.stopBtn]];
    bottom.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottom.alignment = NSLayoutAttributeBottom;
    bottom.spacing = 6;
    [self.inputScroll setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.root = [NSStackView stackViewWithViews:@[top, self.prog, self.status, self.attachBar, sv, bottom]];
    self.root.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.root.alignment = NSLayoutAttributeLeading;
    self.root.spacing = 8;
    self.root.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:self.root];
    [NSLayoutConstraint activateConstraints:@[
        [self.root.topAnchor constraintEqualToAnchor:cv.topAnchor constant:14],
        [self.root.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:14],
        [self.root.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-14],
        [self.root.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor constant:-14],
        [top.widthAnchor constraintEqualToAnchor:self.root.widthAnchor],
        [self.prog.widthAnchor constraintEqualToAnchor:self.root.widthAnchor],
        [self.status.widthAnchor constraintEqualToAnchor:self.root.widthAnchor],
        [self.attachBar.widthAnchor constraintEqualToAnchor:self.root.widthAnchor],
        [sv.widthAnchor constraintEqualToAnchor:self.root.widthAnchor],
        [bottom.widthAnchor constraintEqualToAnchor:self.root.widthAnchor],
    ]];
    [self showAttachBar:NO];

    self.win.delegate = self;
    [self buildMenu];
    [self.win makeKeyAndOrderFront:nil];
    [self.win layoutIfNeeded];
    [self syncTextWidths];
    dispatch_async(dispatch_get_main_queue(), ^{ [self syncTextWidths]; });
    [NSApp activateIgnoringOtherApps:YES];

    if (self.gpuIndex < 0) {
        [self say:@"system" text:@"I cannot find a graphics card to run on. This app needs a "
                                @"Metal-capable GPU, and there does not seem to be one here."];
    } else {
        BOOL haveOne = NO;
        for (ModelSpec *m in Catalogue()) if ([self modelPresent:m]) { haveOne = YES; break; }
        [self say:@"system" text:[NSString stringWithFormat:
            @"Hello. I will be running on your %@, which has %.1f GB of graphics memory to work "
            @"with.\n\n%@\n\nEverything happens on this Mac. Nothing you type, and no document "
            @"you open, ever leaves it.\n\nOnce it is running you can drop a document on this "
            @"window and ask me to read it, or press ⌘D and I will write one for you.",
            self.gpuName, self.gpuVRAM,
            haveOne ? @"Press Start when you are ready."
                    : @"Pick a model above and press Download — it only has to happen once."]];
        if (!self.gpuMetal3) {
            [self say:@"system" text:
             @"⚠️  This card cannot run the model, I am afraid. It does not support the "
             @"Metal 3 features the maths depends on — the Radeon Pro 580X fitted to many Mac "
             @"Pros is one of these. If your Mac also has a Vega II, I will use that instead; "
             @"if not, there is nothing this app can do here."];
        } else {
            [self say:@"system" text:
             @"One honest note: this has only ever been tested on a single machine — a Mac Pro "
             @"(2019) with a Radeon Pro Vega II. Anything else, including a different Vega II, "
             @"is unknown territory. If it works on yours, or doesn't, the author would like "
             @"to hear about it."];
        }
        if (self.gpuVRAM < 7.0)
            [self say:@"system" text:@"A word of warning: this card has not much memory to spare, so "
                                @"stick to one of the smaller models and expect replies to take their time."];
    }
    {   // of the models already downloaded, open on the quickest one that fits
        NSArray<ModelSpec *> *c = Catalogue();
        NSInteger best = -1; double bestScore = -1;
        for (NSUInteger i = 0; i < c.count; i++) {
            if (![self modelPresent:c[i]]) continue;
            if (self.gpuVRAM > 0 && c[i].needGiB > 0 && c[i].needGiB > self.gpuVRAM) continue;
            double score = [c[i] expectedTPS];
            if (score > bestScore) { bestScore = score; best = (NSInteger) i; }
            if (best < 0) best = (NSInteger) i;
        }
        if (best >= 0) [self.modelPop selectItemAtIndex:best];
    }
    [self modelChanged:nil];
    // Get the kernels compiled while the welcome text is still being read.
    if (self.gpuIndex >= 0 && self.gpuMetal3) {
        [self showStatus:@"Getting your graphics card ready…"];
        __weak AppDelegate *weakSelf = self;
        [[MVEngine shared] warmUpForDevice:self.gpuName completion:^(double secs) {
            AppDelegate *me = weakSelf; if (!me) return;
            me.warmedUp = YES;
            [me say:@"system" text:[NSString stringWithFormat:
                @"Your card is ready (%.0f seconds spent building the code it runs — that "
                @"happens once each time the app opens). Pressing Start now only has to load "
                @"the model itself.", secs]];
            [me modelChanged:nil];
        }];
    }
    if (MVAutoStart() && [self modelPresent:[self selectedModel]])
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self startEngine]; });
}

// A text view inside a scroll view wraps at its own frame width, which
// autoresizing gets wrong when the view is built before the window is laid out.
- (void)syncTextWidths {
    for (NSTextView *tv in @[self.transcript, self.input]) {
        NSClipView *clip = tv.enclosingScrollView.contentView;
        CGFloat w = NSWidth(clip.bounds);
        if (w < 1) continue;
        NSRect f = tv.frame;
        f.size.width = w;
        tv.frame = f;
        tv.textContainer.containerSize = NSMakeSize(w - 2 * tv.textContainerInset.width, FLT_MAX);
    }
}
- (void)windowDidResize:(NSNotification *)n { [self syncTextWidths]; }

- (void)buildAttachBar {
    NSView *bar = [[NSView alloc] initWithFrame:NSZeroRect];
    bar.wantsLayer = YES;
    bar.layer.cornerRadius = 6;
    bar.layer.backgroundColor = [NSColor controlBackgroundColor].CGColor;
    bar.layer.borderWidth = 1;
    bar.layer.borderColor = [NSColor separatorColor].CGColor;

    NSTextField *icon = [NSTextField labelWithString:@"📄"];
    self.attachLabel = [NSTextField labelWithString:@""];
    self.attachLabel.font = [NSFont systemFontOfSize:12];
    self.attachLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    self.reviewPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [self.reviewPop addItemWithTitle:@"Review…"];   // title item for a pull-down
    for (MVTask *t in [MVTask all]) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:t.menuTitle
                                                    action:@selector(runTaskFromMenu:)
                                             keyEquivalent:@""];
        it.target = self;
        it.tag = t.kind;
        [self.reviewPop.menu addItem:it];
    }
    [self.reviewPop.menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *draft = [[NSMenuItem alloc] initWithTitle:@"Write something based on it…"
                                                   action:@selector(newDraft:) keyEquivalent:@""];
    draft.target = self;
    [self.reviewPop.menu addItem:draft];

    NSButton *x = [NSButton buttonWithTitle:@"✕" target:self action:@selector(detachDocumentAction:)];
    x.bezelStyle = NSBezelStyleInline;
    x.toolTip = @"Put the document aside";

    NSStackView *s = [NSStackView stackViewWithViews:@[icon, self.attachLabel, self.reviewPop, x]];
    s.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    s.spacing = 8;
    s.edgeInsets = NSEdgeInsetsMake(6, 10, 6, 8);
    s.translatesAutoresizingMaskIntoConstraints = NO;
    [self.attachLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [bar addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [s.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [s.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [s.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
    ]];
    self.attachBar = bar;
}

- (void)showAttachBar:(BOOL)show {
    self.attachBar.hidden = !show;
    [self.root setVisibilityPriority:(show ? NSStackViewVisibilityPriorityMustHold : NSStackViewVisibilityPriorityNotVisible)
                             forView:self.attachBar];
}

- (void)buildMenu {
    NSMenu *mb = [NSMenu new];

    NSMenuItem *appItem = [NSMenuItem new]; [mb addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"About MacVegaII Chat" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [[appMenu addItemWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@","] setTarget:self];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [[appMenu addItemWithTitle:@"Use a Model File…" action:@selector(chooseModelFile:) keyEquivalent:@""] setTarget:self];
    [[appMenu addItemWithTitle:@"Reveal Models in Finder" action:@selector(revealModels:) keyEquivalent:@""] setTarget:self];
    [[appMenu addItemWithTitle:@"Delete the Downloaded Model…" action:@selector(deleteModel:) keyEquivalent:@""] setTarget:self];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    NSMenuItem *fileItem = [NSMenuItem new]; [mb addItem:fileItem];
    NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
    [[file addItemWithTitle:@"New Chat" action:@selector(startNewChat:) keyEquivalent:@"n"] setTarget:self];
    [[file addItemWithTitle:@"Open Document…" action:@selector(openDocument:) keyEquivalent:@"o"] setTarget:self];
    [file addItem:[NSMenuItem separatorItem]];
    [[file addItemWithTitle:@"Save Chat…" action:@selector(saveTranscript:) keyEquivalent:@"s"] setTarget:self];
    [file addItem:[NSMenuItem separatorItem]];
    [file addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    fileItem.submenu = file;

    NSMenuItem *editItem = [NSMenuItem new]; [mb addItem:editItem];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItemWithTitle:@"Undo"       action:@selector(undo:)      keyEquivalent:@"z"];
    [edit addItemWithTitle:@"Redo"       action:@selector(redo:)      keyEquivalent:@"Z"];
    [edit addItem:[NSMenuItem separatorItem]];
    [edit addItemWithTitle:@"Cut"        action:@selector(cut:)       keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy"       action:@selector(copy:)      keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste"      action:@selector(paste:)     keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;

    NSMenuItem *docItem = [NSMenuItem new]; [mb addItem:docItem];
    NSMenu *doc = [[NSMenu alloc] initWithTitle:@"Document"];
    for (MVTask *t in [MVTask all]) {
        NSMenuItem *it = [doc addItemWithTitle:t.menuTitle action:@selector(runTaskFromMenu:) keyEquivalent:@""];
        it.target = self;
        it.tag = t.kind;
    }
    [doc addItem:[NSMenuItem separatorItem]];
    [[doc addItemWithTitle:@"Write a Document…" action:@selector(newDraft:) keyEquivalent:@"d"] setTarget:self];
    [[doc addItemWithTitle:@"Open Last Answer as a Draft" action:@selector(answerToDraft:) keyEquivalent:@"D"] setTarget:self];
    [doc addItem:[NSMenuItem separatorItem]];
    [[doc addItemWithTitle:@"Put the Document Aside" action:@selector(detachDocumentAction:) keyEquivalent:@""] setTarget:self];
    docItem.submenu = doc;

    NSMenuItem *winItem = [NSMenuItem new]; [mb addItem:winItem];
    NSMenu *wm = [[NSMenu alloc] initWithTitle:@"Window"];
    [wm addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [wm addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [wm addItem:[NSMenuItem separatorItem]];
    [wm addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];
    winItem.submenu = wm;
    NSApp.windowsMenu = wm;

    NSApp.mainMenu = mb;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL a = item.action;
    if (a == @selector(runTaskFromMenu:))       return self.document != nil && [self engineRunning] && !self.busy;
    if (a == @selector(detachDocumentAction:))  return self.document != nil;
    if (a == @selector(newDraft:))              return [self engineRunning] && !self.busy;
    if (a == @selector(answerToDraft:))         return self.lastAnswer.length > 0;
    if (a == @selector(saveTranscript:))        return self.transcript.string.length > 0;
    if (a == @selector(deleteModel:))           return [self modelPresent:[self selectedModel]] && !self.engineOn;
    if (a == @selector(chooseModelFile:))       return !self.engineOn;
    if (a == @selector(openDocument:))          return !self.busy;
    return YES;
}

- (void)revealModels:(id)s {
    [[NSWorkspace sharedWorkspace] selectFile:nil inFileViewerRootedAtPath:[self supportDir]];
}

#pragma mark Transcript

- (NSString *)transcriptText { return self.transcript.string ?: @""; }
- (NSString *)statusText { return self.status.stringValue ?: @""; }
- (BOOL)engineRunning { return self.ready && [MVEngine shared].loaded; }

- (void)say:(NSString *)role text:(NSString *)t {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSColor *c = [role isEqual:@"you"] ? [NSColor systemBlueColor]
                   : [role isEqual:@"system"] ? [NSColor secondaryLabelColor] : [NSColor labelColor];
        NSString *prefix = [role isEqual:@"system"] ? @"" : [NSString stringWithFormat:@"%@\n", [role uppercaseString]];
        NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:
            [NSString stringWithFormat:@"%@%@\n\n", prefix, t]];
        [a addAttribute:NSForegroundColorAttributeName value:c range:NSMakeRange(0, a.length)];
        [a addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:MVTextSize()] range:NSMakeRange(0, a.length)];
        [self.transcript.textStorage appendAttributedString:a];
        [self.transcript scrollRangeToVisible:NSMakeRange(self.transcript.string.length, 0)];
    });
}
- (void)appendDelta:(NSString *)d {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:d];
        [a addAttribute:NSForegroundColorAttributeName value:[NSColor labelColor] range:NSMakeRange(0, a.length)];
        [a addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:MVTextSize()] range:NSMakeRange(0, a.length)];
        [self.transcript.textStorage appendAttributedString:a];
        [self.transcript scrollRangeToVisible:NSMakeRange(self.transcript.string.length, 0)];
    });
}
- (void)appendThinking:(NSString *)d {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:d];
        [a addAttribute:NSForegroundColorAttributeName value:[NSColor tertiaryLabelColor] range:NSMakeRange(0, a.length)];
        [a addAttribute:NSFontAttributeName
                  value:[[NSFontManager sharedFontManager] convertFont:[NSFont systemFontOfSize:MVTextSize() - 1] toHaveTrait:NSItalicFontMask]
                  range:NSMakeRange(0, a.length)];
        [self.transcript.textStorage appendAttributedString:a];
        [self.transcript scrollRangeToVisible:NSMakeRange(self.transcript.string.length, 0)];
    });
}
- (void)showStatus:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{ self.status.stringValue = s ?: @""; });
}

- (void)saveTranscript:(id)sender {
    NSSavePanel *p = [NSSavePanel savePanel];
    p.nameFieldStringValue = @"Chat.md";
    [p beginSheetModalForWindow:self.win completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK || !p.URL) return;
        NSError *e = nil;
        [self.transcript.string writeToURL:p.URL atomically:YES encoding:NSUTF8StringEncoding error:&e];
        [self showStatus:e ? [NSString stringWithFormat:@"Could not save: %@", e.localizedDescription]
                           : [NSString stringWithFormat:@"Chat saved to %@.", p.URL.path]];
    }];
}

#pragma mark Model selection

- (void)modelChanged:(id)sender {
    if ([self chooseFileItemSelected]) {          // the "…I already have" row
        [self.modelPop selectItemAtIndex:0];
        [self chooseModelFile:nil];
        return;
    }
    ModelSpec *m = [self selectedModel];
    BOOL have = [self modelPresent:m];
    self.actionBtn.title = self.engineOn ? @"Put Away" : (have ? @"Start" : @"Download");
    if (self.engineOn) return;
    if (!self.warmedUp && self.gpuIndex >= 0 && self.gpuMetal3) return;  // warm-up owns the status line

    if (!have && !m.url) {
        [self showStatus:@"That file is not where it used to be — choose it again."];
    } else if (!have) {
        [self showStatus:[NSString stringWithFormat:
            @"Not on this Mac yet — %.1f GB to download, once.", m.gib]];
    } else if (self.gpuVRAM > 0 && m.needGiB > 0 && self.gpuVRAM < m.needGiB) {
        [self showStatus:[NSString stringWithFormat:
            @"Ready, but it is a squeeze: this one is happiest with about %.0f GB of graphics "
            @"memory and your card has %.1f GB. It may be slow, or refuse to start.",
            m.needGiB, self.gpuVRAM]];
    } else {
        [self showStatus:[NSString stringWithFormat:@"On this Mac and ready — press Start.%@",
                          [self speedNote:m]]];
    }
}

// A token is about three quarters of a word, so the conversion is honest enough
// to be useful and vague enough not to pretend otherwise.
- (NSString *)speedNote:(ModelSpec *)m {
    double t = [m expectedTPS];
    if (t <= 0) return @"  Nobody has timed this one yet.";
    NSInteger words = (NSInteger) lround(t * 0.75);
    if ([m tpsIsYourOwn])
        return [NSString stringWithFormat:@"  You have been getting about %ld words a second "
                                          @"out of it.", (long)words];
    return [NSString stringWithFormat:@"  Expect about %ld words a second — that is what it "
                                      @"managed on a Vega II.", (long)words];
}

- (void)chooseModelFile:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.message = @"Choose a GGUF model file you already have.";
    UTType *gguf = [UTType typeWithFilenameExtension:@"gguf"];
    if (gguf) p.allowedContentTypes = @[gguf];
    p.allowsMultipleSelection = NO;
    [p beginSheetModalForWindow:self.win completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK || !p.URL) return;
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:p.URL.path];
        NSData *magic = [fh readDataOfLength:4];
        [fh closeFile];
        if (magic.length != 4 || memcmp(magic.bytes, "GGUF", 4) != 0) {
            [self say:@"system" text:@"That file is not a GGUF model."];
            return;
        }
        [[NSUserDefaults standardUserDefaults] setObject:p.URL.path forKey:MVPrefCustomModelPath];
        [self rebuildModelMenu];
        [self.modelPop selectItemAtIndex:Catalogue().count - 1];
        [self modelChanged:nil];
        [self say:@"system" text:[NSString stringWithFormat:
            @"Using %@. Press Start.\n\nWorth knowing before you rely on it: a model you "
            @"bring yourself is not tested here and not recommended. It will most likely "
            @"run — but a model can be subtly wrong in ways that take a long while to "
            @"notice, and nothing on screen will tell you. The models in the list above were "
            @"chosen for this card.\n\nIf there is a small model you would like "
            @"tested on this hardware, raise an issue on the project. We may eventually get "
            @"around to it, and that is the whole of what we can promise.",
            p.URL.lastPathComponent]];
    }];
}

- (void)deleteModel:(id)sender {
    ModelSpec *m = [self selectedModel];
    if (!m.url) {   // just forget a user-chosen file; never delete something we did not download
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:MVPrefCustomModelPath];
        [self rebuildModelMenu];
        [self modelChanged:nil];
        return;
    }
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:@"Delete %@?", m.file];
    a.informativeText = [NSString stringWithFormat:
        @"This frees about %.1f GB. You can download it again later.", m.gib];
    [a addButtonWithTitle:@"Delete"];
    [a addButtonWithTitle:@"Cancel"];
    [a beginSheetModalForWindow:self.win completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        NSError *e = nil;
        [[NSFileManager defaultManager] removeItemAtPath:[self modelPath:m] error:&e];
        [self modelChanged:nil];
        if (e) [self showStatus:[NSString stringWithFormat:@"Could not delete it: %@", e.localizedDescription]];
    }];
}

#pragma mark Conversation bookkeeping

- (void)startNewChat:(id)sender {
    [self.history removeAllObjects];
    [self.transcript.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
    self.lastAnswer = nil;
    if (self.document) {
        // keep the document, but it has to go back into the fresh conversation
        MVDocument *d = self.document;
        self.document = nil;
        [self attachDocument:d];
    }
    if ([self engineRunning])
        [self showStatus:[NSString stringWithFormat:@"Ready — %@", [self currentModelName]]];
    [self say:@"system" text:@"Starting fresh — I have forgotten everything we said before."];
}

// Now that the tokeniser is in the process, the context meter can be honest.
- (NSInteger)tokensIn:(NSString *)s {
    if (!s.length) return 0;
    if ([MVEngine shared].loaded) return [[MVEngine shared] countTokens:s];
    return MVEstimateTokens(s);
}
- (NSInteger)estimateTokens {
    NSInteger n = 0;
    for (NSDictionary *m in self.history) n += [self tokensIn:m[@"content"]] + 6;
    return n;
}

// The whole conversation is resent each turn, so it eventually outgrows the context
// window. Drop the oldest exchanges rather than letting the request fail.
- (void)trimHistoryIfNeeded {
    // The KV cache holds the prompt prefix, so a follow-up question only evaluates the
    // new tokens - measured here as 21.2s cold vs 1.3s warm on a 1460-token conversation.
    // Dropping the OLDEST messages changes that prefix and throws the cache away, forcing
    // a full reprocess.
    //
    // So trim with hysteresis: do nothing until 70% full, then cut back to 40%. Trimming to
    // just under the limit instead would re-trim on every subsequent turn, invalidating the
    // cache every turn and making every reply permanently slow.
    NSInteger ctx = MVContextTokens();
    const NSInteger high = ctx * 7 / 10;
    const NSInteger low  = ctx * 4 / 10;
    if ([self estimateTokens] <= high) return;

    // An attached document sits at the front of the conversation. Trimming it away
    // would silently turn "summarise it" into a question about nothing, so it stays.
    NSUInteger pinned = (self.document && self.document.inContext) ? 1 : 0;
    NSMutableArray<NSNumber *> *cost = [NSMutableArray array];
    NSInteger total = 0;
    for (NSDictionary *m in self.history) {
        NSInteger c = [self tokensIn:m[@"content"]] + 6;
        [cost addObject:@(c)];
        total += c;
    }
    BOOL trimmed = NO;
    while (total > low && self.history.count > pinned + 2) {
        total -= cost[pinned].integerValue;
        [self.history removeObjectAtIndex:pinned];
        [cost removeObjectAtIndex:pinned];
        if (self.history.count > pinned && [self.history[pinned][@"role"] isEqual:@"assistant"]) {
            total -= cost[pinned].integerValue;
            [self.history removeObjectAtIndex:pinned];
            [cost removeObjectAtIndex:pinned];
        }
        trimmed = YES;
    }
    if (trimmed)
        [self say:@"system" text:@"(the conversation got long, so I have let go of the earliest "
                                  @"messages to make room. This next reply will take a little longer "
                                  @"while I re-read what is left.)"];
}

- (NSArray *)messagesForPrompt:(NSString *)prompt {
    NSMutableArray *m = [NSMutableArray array];
    NSString *sys = MVSystemPrompt();
    if (sys.length) [m addObject:@{@"role": @"system", @"content": sys}];
    [m addObject:@{@"role": @"user", @"content": prompt}];
    return m;
}
- (NSArray *)messagesForHistory {
    NSMutableArray *m = [NSMutableArray array];
    NSString *sys = MVSystemPrompt();
    if (sys.length) [m addObject:@{@"role": @"system", @"content": sys}];
    [m addObjectsFromArray:self.history];
    return m;
}

#pragma mark Download and server

- (void)action:(id)sender {
    if (self.engineOn) { [self stopEngine]; return; }
    ModelSpec *m = [self selectedModel];
    if ([self modelPresent:m]) [self startEngine]; else [self startDownload];
}

- (void)startDownload {
    ModelSpec *m = [self selectedModel];
    if (!m.url) { [self showStatus:@"That model file has gone missing."]; return; }
    self.actionBtn.enabled = NO; self.modelPop.enabled = NO;
    self.prog.hidden = NO; self.prog.doubleValue = 0;
    [self showStatus:[NSString stringWithFormat:@"Downloading %@ (%.1f GB)…", m.file, m.gib]];
    NSURLSessionConfiguration *c = [NSURLSessionConfiguration defaultSessionConfiguration];
    c.timeoutIntervalForResource = 60*60*8;
    self.dl = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:nil];
    [[self.dl downloadTaskWithURL:[NSURL URLWithString:m.url]] resume];
}
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t
      didWriteData:(int64_t)w totalBytesWritten:(int64_t)tot totalBytesExpectedToWrite:(int64_t)exp {
    if (exp <= 0) return;
    double f = (double)tot/(double)exp;
    dispatch_async(dispatch_get_main_queue(), ^{ self.prog.doubleValue = f; });
    [self showStatus:[NSString stringWithFormat:@"Downloading… %.1f%%  (%.2f / %.2f GB)",
        f*100, tot/1e9, exp/1e9]];
}
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t
      didFinishDownloadingToURL:(NSURL *)loc {
    ModelSpec *m = [self selectedModel];
    NSString *dst = [self modelPath:m];
    [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
    NSError *e = nil;
    [[NSFileManager defaultManager] moveItemAtPath:loc.path toPath:dst error:&e];

    // sanity-check the result: a GGUF always starts with the magic "GGUF"
    if (!e) {
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:dst];
        NSData *magic = [fh readDataOfLength:4];
        [fh closeFile];
        if (magic.length != 4 || memcmp(magic.bytes, "GGUF", 4) != 0) {
            [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
            e = [NSError errorWithDomain:@"MacVegaIIChat" code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"the downloaded file is not a valid model — please try again"}];
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        self.prog.hidden = YES; self.actionBtn.enabled = YES; self.modelPop.enabled = YES;
        if (e) { [self showStatus:[NSString stringWithFormat:@"Download failed: %@", e.localizedDescription]]; }
        else { [self showStatus:@"Downloaded. Press Start."]; [self modelChanged:nil]; }
    });
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e {
    if (!e) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.prog.hidden = YES; self.actionBtn.enabled = YES; self.modelPop.enabled = YES;
        // A late or spurious error can arrive after the file has already been written.
        // Trust the file on disk over the error: telling someone their 18 GB download
        // failed when it did not is worse than saying nothing.
        if ([self modelPresent:[self selectedModel]]) {
            [self showStatus:@"Downloaded. Press Start."];
            [self modelChanged:nil];
        } else if (e.code == NSURLErrorCancelled) {
            [self showStatus:@"Download cancelled."];
        } else {
            [self showStatus:[NSString stringWithFormat:@"Download failed: %@", e.localizedDescription]];
        }
    });
}

- (void)startEngine {
    ModelSpec *m = [self selectedModel];
    self.engineOn = YES;
    self.ready = NO;
    self.actionBtn.title = @"Put Away";
    self.modelPop.enabled = NO;
    self.prog.hidden = NO;
    self.prog.doubleValue = 0;
    [self showStatus:@"Getting the model ready…"];
    [self say:@"system" text:[NSString stringWithFormat:
        @"Waking up %@ on your %@. The first time takes a minute or so — after that it stays "
        @"ready until you put it away.", m.file.lastPathComponent, self.gpuName]];

    __weak AppDelegate *weakSelf = self;
    [[MVEngine shared] loadModel:[self modelPath:m]
                      deviceName:self.gpuName
                   contextTokens:MVContextTokens()
                        progress:^(float f) {
        AppDelegate *me = weakSelf; if (!me) return;
        me.prog.doubleValue = f;
        [me showStatus:[NSString stringWithFormat:@"Getting the model ready… %.0f%%", f * 100]];
    }
                      completion:^(NSString *err) {
        AppDelegate *me = weakSelf; if (!me) return;
        me.prog.hidden = YES;
        if (err) {
            me.engineOn = NO;
            me.modelPop.enabled = YES;
            [me say:@"system" text:[NSString stringWithFormat:
                @"That model would not load. %@\n\nIf it is a big model on a small card, try the "
                @"smaller one, or lower the memory setting in Settings.", err]];
            [me showStatus:@"The model would not load."];
            [me modelChanged:nil];
            return;
        }
        me.ready = YES;
        me.input.editable = YES;
        me.sendBtn.enabled = YES;
        [me showStatus:[NSString stringWithFormat:@"Ready — %@ on your %@.",
                        [me currentModelName], me.gpuName]];
        [me say:@"system" text:@"Ready when you are. Type below, or drop a document on the "
                               @"window and I will read it."];

        // Every GGUF carries its own instructions for how to lay out a conversation,
        // and we follow them. When one doesn't, say so — it is the likeliest reason
        // for a model that seems oddly stupid.
        if (![MVEngine shared].modelHasOwnTemplate)
            [me say:@"system" text:@"One thing worth knowing: this file does not say how it "
                                   @"likes conversations to be laid out, so I am using a common "
                                   @"format instead. It will work, but the answers may be a "
                                   @"little off. The models in the list above all bring their "
                                   @"own."];
        else if (![MVEngine shared].modelCanThink && MVThinkingEnabled())
            [me say:@"system" text:@"This model answers straight away rather than working things "
                                   @"through first, so the thinking setting in Settings makes no "
                                   @"difference to it."];
        [me.win makeFirstResponder:me.input];
        if (me.document && !me.document.inContext) [me attachDocument:me.document];
    }];
}

- (void)stopEngine {
    self.cancelled = YES;
    [self.generation cancel];
    self.generation = nil;
    [[MVEngine shared] unload];
    self.engineOn = NO;
    self.ready = NO;
    self.busy = NO;
    self.input.editable = NO;
    self.sendBtn.enabled = NO;
    self.stopBtn.enabled = NO;
    self.modelPop.enabled = YES;
    self.prog.hidden = YES;
    [self showStatus:@"Put away. The card is free again."];
    [self modelChanged:nil];
}

#pragma mark Input

- (BOOL)textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (tv != self.input) return NO;
    if (sel == @selector(insertNewline:)) { [self send:nil]; return YES; }
    if (sel == @selector(insertLineBreak:)) { [tv insertText:@"\n" replacementRange:tv.selectedRange]; return YES; }
    return NO;
}
- (void)textDidChange:(NSNotification *)n {
    if (n.object != self.input) return;
    // Grow the box with the text, up to about six lines, then let it scroll.
    NSLayoutManager *lm = self.input.layoutManager;
    [lm ensureLayoutForTextContainer:self.input.textContainer];
    CGFloat h = [lm usedRectForTextContainer:self.input.textContainer].size.height + 14;
    self.inputHeight.constant = MAX(38, MIN(140, h));
}

#pragma mark Documents

- (void)openDocument:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.message = @"Choose a document for the model to read.";
    p.allowsMultipleSelection = NO;
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    for (NSString *e in MVDocumentExtensions()) {
        UTType *t = [UTType typeWithFilenameExtension:e];
        if (t) [types addObject:t];
    }
    p.allowedContentTypes = types;
    [p beginSheetModalForWindow:self.win completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK || !p.URL) return;
        NSString *err = nil;
        if (![self attachDocumentAtPath:p.URL.path error:&err])
            [self say:@"system" text:[NSString stringWithFormat:@"Could not read %@ — %@",
                                      p.URL.lastPathComponent, err]];
    }];
}

- (BOOL)attachDocumentAtPath:(NSString *)path error:(NSString **)err {
    NSError *e = nil;
    MVDocument *d = [MVDocument fromURL:[NSURL fileURLWithPath:path.stringByExpandingTildeInPath] error:&e];
    if (!d) { if (err) *err = e.localizedDescription ?: @"unknown error"; return NO; }
    [self attachDocument:d];
    return YES;
}

// How much document we can put in front of the model in one go, leaving room for
// the instruction and the reply. With the real tokeniser to hand this is measured
// from the document itself rather than guessed at three characters a token.
- (NSInteger)chunkTokenBudget {
    NSInteger budget = MVContextTokens() - MVMaxReplyTokens() - 600;
    return MAX(budget, 512);
}
- (NSUInteger)chunkChars { return (NSUInteger)([self chunkTokenBudget] * 3.4); }
- (NSUInteger)chunkCharsFor:(MVDocument *)doc {
    double perToken = (doc.tokens > 0) ? (double) doc.text.length / (double) doc.tokens : 3.4;
    return (NSUInteger)([self chunkTokenBudget] * perToken * 0.95);
}

- (void)attachDocument:(MVDocument *)d {
    self.document = d;
    if ([MVEngine shared].loaded) d.tokens = [self tokensIn:d.text];
    NSUInteger budget = [self chunkCharsFor:d];
    d.inContext = NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        self.attachLabel.stringValue = [d summaryLine];
        [self showAttachBar:YES];
    });

    if (d.text.length <= budget && [self engineRunning]) {
        // Small enough to live in the conversation: put it in once, so follow-up
        // questions are ordinary turns and the prompt cache keeps working.
        [self.history insertObject:@{@"role": @"user", @"content":
            [NSString stringWithFormat:
             @"Here is a document called “%@”. Read it and keep it in mind; I will ask about "
             @"it next.\n\n-----\n%@\n-----", d.name, d.text]} atIndex:0];
        [self.history insertObject:@{@"role": @"assistant", @"content":
            [NSString stringWithFormat:@"I have read “%@” and I am ready for your questions about it.", d.name]}
                           atIndex:1];
        d.inContext = YES;
        [self say:@"system" text:[NSString stringWithFormat:
            @"📄 I have read “%@” — %ld words, and it fits comfortably in mind. Ask me anything "
            @"about it, or use the Review button above for the usual jobs.",
            d.name, (long)d.words]];
    } else if ([self engineRunning]) {
        NSUInteger parts = MVSplitIntoChunks(d.text, budget).count;
        [self say:@"system" text:[NSString stringWithFormat:
            @"📄 “%@” is %ld words, which is more than I can hold in mind in one go. I will read "
            @"it in %lu passes each time you ask something, so those answers will take a while. "
            @"If you would rather they didn't, raise the memory setting in Settings.",
            d.name, (long)d.words, (unsigned long)parts]];
    } else {
        [self say:@"system" text:[NSString stringWithFormat:
            @"📄 “%@” is here — %ld words. Press Start to wake the model up and I will read it.",
            d.name, (long)d.words]];
    }
}

- (void)detachDocument {
    if (!self.document) return;
    if (self.document.inContext && self.history.count >= 2 &&
        [self.history[0][@"content"] containsString:self.document.name]) {
        [self.history removeObjectAtIndex:0];
        [self.history removeObjectAtIndex:0];
    }
    NSString *name = self.document.name;
    self.document = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [self showAttachBar:NO]; });
    [self say:@"system" text:[NSString stringWithFormat:
        @"Put “%@” aside. Ask me for it again whenever you like.", name]];
}
- (void)detachDocumentAction:(id)sender { [self detachDocument]; }

- (void)runTaskFromMenu:(NSMenuItem *)item {
    if (!self.document) return;
    [self runTask:[MVTask forKind:(MVTaskKind)item.tag] onDocument:self.document completion:nil];
}

#pragma mark Asking

- (void)send:(id)sender {
    NSString *q = [self.input.string stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!q.length || ![self engineRunning] || self.busy) return;
    self.input.string = @"";
    self.inputHeight.constant = 38;
    [self askQuestion:q completion:nil];
}
- (void)stopGen:(id)sender {
    self.cancelled = YES;
    [self.generation cancel];
}

- (void)beginBusy {
    self.busy = YES;
    self.cancelled = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.sendBtn.enabled = NO; self.input.editable = NO; self.stopBtn.enabled = YES;
    });
}
- (void)endBusy {
    self.busy = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.sendBtn.enabled = [self engineRunning];
        self.input.editable = [self engineRunning];
        self.stopBtn.enabled = NO;
        self.prog.hidden = YES;
        [self.win makeFirstResponder:self.input];
    });
}

// A question typed into the box, or sent by AppleScript: identical either way.
- (void)askQuestion:(NSString *)q completion:(void (^)(NSString *, NSString *))done {
    if (![self engineRunning]) { if (done) done(nil, @"the engine is not running"); return; }
    if (self.busy) { if (done) done(nil, @"the model is already busy"); return; }

    // A document too big for the conversation has to be re-read for every question.
    if (self.document && !self.document.inContext) {
        [self runTask:[MVTask questionTask:q] onDocument:self.document completion:done];
        return;
    }

    [self say:@"you" text:q];
    [self.history addObject:@{@"role":@"user", @"content":q}];
    [self trimHistoryIfNeeded];
    [self beginBusy];
    [self streamIntoTranscript:[self messagesForHistory] thinking:MVThinkingEnabled()
               recordInHistory:YES completion:done];
}

// Runs one generation, showing the thinking as it arrives so the window does not
// look hung, then folding it away once the answer starts and re-rendering the
// answer with Markdown applied.
- (void)streamIntoTranscript:(NSArray *)messages
                    thinking:(BOOL)thinking
             recordInHistory:(BOOL)record
                  completion:(void (^)(NSString *, NSString *))done {
    self.pending = [NSMutableString string];
    [self appendDelta:@"ASSISTANT\n"];
    BOOL keepThinking = MVShowThinking();
    __block NSUInteger thinkStart = NSNotFound;
    __block NSUInteger answerStart = 0;
    __block NSDate *thinkBegan = nil;
    __block BOOL sawThinking = NO;
    __weak AppDelegate *weakSelf = self;

    self.generation = [MVGeneration runWithMessages:messages
        maxTokens:MVMaxReplyTokens() temperature:MVTemperature() thinking:thinking
        onDelta:^(NSString *content, NSString *reasoning) {
            AppDelegate *me = weakSelf; if (!me) return;
            if (reasoning.length) {
                if (!sawThinking) {
                    sawThinking = YES;
                    thinkBegan = [NSDate date];
                    // Deltas are appended asynchronously on the main queue, so read the
                    // insertion point there too: by then everything before it has landed.
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        thinkStart = me.transcript.textStorage.length;
                    });
                    [me appendThinking:@"thinking… "];
                }
                [me appendThinking:reasoning];
            }
            if (content.length) {
                if (me.pending.length == 0) {
                    NSTimeInterval took = thinkBegan ? -[thinkBegan timeIntervalSinceNow] : 0;
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        NSTextStorage *ts = me.transcript.textStorage;
                        if (thinkStart != NSNotFound && thinkStart <= ts.length) {
                            // Nobody wants three screens of deliberation left above the
                            // answer, but the fact that it happened is worth a line.
                            NSString *note = keepThinking ? @"\n\n"
                                : [NSString stringWithFormat:@"thought for %.0f s\n\n", took];
                            NSMutableAttributedString *a =
                                [[NSMutableAttributedString alloc] initWithString:note];
                            [a addAttributes:@{
                                NSForegroundColorAttributeName: [NSColor tertiaryLabelColor],
                                NSFontAttributeName: [[NSFontManager sharedFontManager]
                                    convertFont:[NSFont systemFontOfSize:MVTextSize() - 1]
                                    toHaveTrait:NSItalicFontMask]}
                                       range:NSMakeRange(0, a.length)];
                            if (keepThinking) [ts appendAttributedString:a];
                            else [ts replaceCharactersInRange:NSMakeRange(thinkStart, ts.length - thinkStart)
                                        withAttributedString:a];
                        }
                        answerStart = ts.length;
                    });
                }
                [me.pending appendString:content];
                [me appendDelta:content];
            }
        }
        onDone:^(NSString *text, NSString *errorMessage, NSDictionary *timings) {
            AppDelegate *me = weakSelf; if (!me) return;
            me.generation = nil;
            if (errorMessage) {
                BOOL dead = ![me engineRunning];
                [me appendDelta:[NSString stringWithFormat:@"\n[%@]\n",
                    dead ? @"the engine stopped — press Start to restart it" : errorMessage]];
                if (dead) dispatch_async(dispatch_get_main_queue(), ^{ [me stopEngine]; });
            }
            // A reasoning model can spend its entire reply budget deliberating and
            // never reach an answer. Rather than show nothing, ask again with the
            // thinking turned off — which is nearly always enough.
            if (!text.length && !errorMessage && !me.cancelled && thinking && sawThinking) {
                [me appendThinking:@"that used the whole reply budget thinking — "
                                   @"asking again without the thinking step\n\n"];
                [me streamIntoTranscript:messages thinking:NO recordInHistory:record completion:done];
                return;
            }
            if (text.length) {
                me.lastAnswer = text;
                if (record) [me.history addObject:@{@"role":@"assistant", @"content":text}];
                NSUInteger start = answerStart;
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSTextStorage *ts = me.transcript.textStorage;
                    if (start <= ts.length)
                        [ts replaceCharactersInRange:NSMakeRange(start, ts.length - start)
                                withAttributedString:MVRenderMarkdown(text, MVTextSize())];
                });
            } else if (!errorMessage && !me.cancelled) {
                [me appendDelta:@"(no answer — try asking again, or raise the reply limit in Settings)"];
            }
            [me appendDelta:@"\n\n"];
            [me noteTimings:timings];
            [me endBusy];
            if (done) done(text, errorMessage);
        }];
}

- (void)noteTimings:(NSDictionary *)t {
    if (![self engineRunning]) return;
    double tps = [t[@"predicted_per_second"] doubleValue];
    double ptps = [t[@"prompt_per_second"] doubleValue];
    NSInteger n = [t[@"predicted_n"] integerValue];

    // A rate measured over a handful of tokens is mostly the cost of getting
    // going — the first few decodes after a big prompt run several times slower
    // than the steady state. Quoting that at someone is worse than saying nothing,
    // so short replies get no speed reported and none recorded.
    NSString *speed = @"";
    if (tps > 0 && n >= 32) {
        MVRecordTPS([self selectedModel].file, tps);
        // Only the generation rate is worth showing. The prompt rate is enormous
        // and meaningless whenever the cache is warm, which is most of the time.
        speed = [NSString stringWithFormat:@"  ·  %.0f words a second", tps * 0.75];
        (void) ptps;
    }
    [self showStatus:[NSString stringWithFormat:@"Ready — %@%@  ·  using about %ld%% of what it can keep in mind",
        [self currentModelName], speed,
        (long)MIN(100, [self estimateTokens]*100/MVContextTokens())]];
}

#pragma mark Reading a long document

- (void)runTask:(MVTask *)task onDocument:(MVDocument *)doc
     completion:(void (^)(NSString *, NSString *))done {
    if (![self engineRunning]) { if (done) done(nil, @"the engine is not running"); return; }
    if (self.busy) { if (done) done(nil, @"the model is already busy"); return; }
    if (!doc) { if (done) done(nil, @"no document is attached"); return; }

    NSString *heading = (task.kind == MVTaskQuestion)
        ? [task.instruction componentsSeparatedByString:@"\n"][0]
        : [NSString stringWithFormat:@"%@ — “%@”", task.menuTitle, doc.name];
    [self say:@"you" text:heading];
    [self beginBusy];

    // Reading tasks are mechanical. Letting the model deliberate first mostly buys a
    // long wait and, on the smaller reply budgets, an answer that never arrives.
    BOOL think = (task.kind == MVTaskQuestion) && MVThinkingEnabled();

    // The easy case: the whole document fits, so this is just another turn.
    if (doc.inContext) {
        [self.history addObject:@{@"role":@"user", @"content":task.instruction}];
        [self trimHistoryIfNeeded];
        [self streamIntoTranscript:[self messagesForHistory] thinking:think
                   recordInHistory:YES completion:done];
        return;
    }

    NSArray<NSString *> *chunks = MVSplitIntoChunks(doc.text, [self chunkCharsFor:doc]);
    if (chunks.count == 1) {
        NSString *p = [NSString stringWithFormat:@"%@\n\nThe document “%@” follows.\n\n-----\n%@\n-----",
                       task.instruction, doc.name, chunks[0]];
        [self streamIntoTranscript:[self messagesForPrompt:p] thinking:think recordInHistory:NO
                        completion:^(NSString *t, NSString *e) {
            [self rememberTask:task document:doc answer:t];
            if (done) done(t, e);
        }];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.prog.hidden = NO; self.prog.minValue = 0;
        self.prog.maxValue = chunks.count + 1; self.prog.doubleValue = 0;
    });
    [self appendThinking:[NSString stringWithFormat:
        @"reading “%@”, %lu passes to go…\n\n", doc.name, (unsigned long)chunks.count]];
    [self readChunks:chunks at:0 task:task document:doc notes:[NSMutableArray array] completion:done];
}

// One pass per chunk, in order. Slower than it looks on paper — but the alternative
// is refusing to read anything longer than the context window.
- (void)readChunks:(NSArray<NSString *> *)chunks at:(NSUInteger)i
              task:(MVTask *)task document:(MVDocument *)doc
             notes:(NSMutableArray<NSString *> *)notes
        completion:(void (^)(NSString *, NSString *))done {
    if (self.cancelled) {
        [self appendDelta:@"\n(stopped)\n\n"];
        [self endBusy];
        if (done) done(nil, @"stopped");
        return;
    }
    if (i >= chunks.count) {
        [self combineNotes:notes task:task document:doc completion:done];
        return;
    }
    [self showStatus:[NSString stringWithFormat:@"Reading “%@” — part %lu of %lu…",
        doc.name, (unsigned long)(i + 1), (unsigned long)chunks.count]];
    dispatch_async(dispatch_get_main_queue(), ^{ self.prog.doubleValue = i; });

    NSString *p = [NSString stringWithFormat:
        @"%@\n\nThis is part %lu of %lu of “%@”.\n\n-----\n%@\n-----",
        task.noteAsk, (unsigned long)(i + 1), (unsigned long)chunks.count, doc.name, chunks[i]];

    __weak AppDelegate *weakSelf = self;
    self.generation = [MVGeneration runWithMessages:[self messagesForPrompt:p]
        maxTokens:MVMaxReplyTokens() temperature:MVTemperature() thinking:NO
        onDelta:nil
        onDone:^(NSString *text, NSString *err, NSDictionary *timings) {
            AppDelegate *me = weakSelf; if (!me) return;
            me.generation = nil;
            if (err) {
                [me appendDelta:[NSString stringWithFormat:@"\n[stopped while reading: %@]\n\n", err]];
                [me endBusy];
                if (done) done(nil, err);
                return;
            }
            [notes addObject:text ?: @""];
            if (task.concatenate && text.length) {
                // Proofreading has nothing to synthesise: the findings are the answer.
                [me appendThinking:[NSString stringWithFormat:@"part %lu read\n", (unsigned long)(i + 1)]];
            }
            [me readChunks:chunks at:i + 1 task:task document:doc notes:notes completion:done];
        }];
}

- (void)combineNotes:(NSArray<NSString *> *)notes task:(MVTask *)task
            document:(MVDocument *)doc completion:(void (^)(NSString *, NSString *))done {
    dispatch_async(dispatch_get_main_queue(), ^{ self.prog.doubleValue = self.prog.maxValue; });

    if (task.concatenate) {
        // Just stitch the per-part findings together, dropping the empty ones.
        NSMutableString *out = [NSMutableString string];
        for (NSUInteger i = 0; i < notes.count; i++) {
            NSString *n = [notes[i] stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!n.length || [n hasPrefix:@"(nothing"]) continue;
            [out appendFormat:@"**Part %lu**\n\n%@\n\n", (unsigned long)(i + 1), n];
        }
        if (!out.length) [out appendString:@"Nothing to report — no problems found."];
        NSString *final = [out copy];
        self.lastAnswer = final;
        [self appendDelta:@"ASSISTANT\n"];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.transcript.textStorage appendAttributedString:MVRenderMarkdown(final, MVTextSize())];
            [self.transcript scrollRangeToVisible:NSMakeRange(self.transcript.string.length, 0)];
        });
        [self appendDelta:@"\n\n"];
        [self rememberTask:task document:doc answer:final];
        [self showStatus:[NSString stringWithFormat:@"Ready — %@", [self currentModelName]]];
        [self endBusy];
        if (done) done(final, nil);
        return;
    }

    [self showStatus:[NSString stringWithFormat:@"Putting the %lu parts of “%@” together…",
        (unsigned long)notes.count, doc.name]];
    NSMutableString *joined = [NSMutableString string];
    for (NSUInteger i = 0; i < notes.count; i++)
        [joined appendFormat:@"--- notes from part %lu ---\n%@\n\n", (unsigned long)(i + 1), notes[i]];

    // If even the notes overflow, summarise the notes first rather than truncating.
    NSString *notesText = joined;
    if (notesText.length > [self chunkChars])
        notesText = [notesText substringToIndex:[self chunkChars]];

    NSString *p = [NSString stringWithFormat:
        @"%@\n\nYou could not read “%@” in one go, so here are your notes from each part, in "
        @"order. Work only from these notes. Do not mention the notes, the parts, or the fact "
        @"that the document was read in pieces — write as though you had read the whole thing.\n\n%@",
        task.instruction, doc.name, notesText];

    [self streamIntoTranscript:[self messagesForPrompt:p] thinking:NO recordInHistory:NO
                    completion:^(NSString *t, NSString *e) {
        [self rememberTask:task document:doc answer:t];
        if (done) done(t, e);
    }];
}

// Keep a short trace in the conversation so follow-up questions have something to
// refer back to, without dragging the whole document along.
- (void)rememberTask:(MVTask *)task document:(MVDocument *)doc answer:(NSString *)answer {
    if (!answer.length) return;
    [self.history addObject:@{@"role":@"user", @"content":
        [NSString stringWithFormat:@"%@ (about the document “%@”)", task.menuTitle, doc.name]}];
    [self.history addObject:@{@"role":@"assistant", @"content":answer}];
    [self trimHistoryIfNeeded];
}

#pragma mark Drafting

- (MVDraftWindow *)frontDraft {
    for (NSWindow *w in NSApp.orderedWindows)
        if ([w.windowController isKindOfClass:[MVDraftWindow class]] && w.isVisible)
            return (MVDraftWindow *)w.windowController;
    return nil;
}

- (void)answerToDraft:(id)sender {
    if (!self.lastAnswer.length) return;
    [MVDraftWindow showWithTitle:@"Draft" text:self.lastAnswer];
}

- (void)generateDraft:(MVDraftSpec *)spec completion:(void (^)(NSString *, NSString *))done {
    if (![self engineRunning]) { if (done) done(nil, @"the engine is not running"); return; }
    if (self.busy) { if (done) done(nil, @"the model is already busy"); return; }

    MVDraftWindow *w = [MVDraftWindow showWithTitle:
        [NSString stringWithFormat:@"%@ (draft)", spec.kind] text:@""];
    [w beginGenerating:@"Writing…"];
    [self beginBusy];
    [self showStatus:[NSString stringWithFormat:@"Writing a %@…", [spec.kind lowercaseString]]];

    __weak AppDelegate *weakSelf = self;
    self.generation = [MVGeneration runWithMessages:[self messagesForPrompt:[spec prompt]]
        maxTokens:MAX(MVMaxReplyTokens(), 3072) temperature:MVTemperature() thinking:NO
        onDelta:^(NSString *content, NSString *reasoning) {
            if (content.length) [w appendDelta:content];
        }
        onDone:^(NSString *text, NSString *err, NSDictionary *timings) {
            AppDelegate *me = weakSelf; if (!me) return;
            me.generation = nil;
            if (text.length) {
                me.lastAnswer = text;
                [w setBodyText:MVStripWrapper(text)];
            }
            [w endGenerating];
            [me noteTimings:timings];
            [me endBusy];
            if (err) [me say:@"system" text:[NSString stringWithFormat:@"The draft stopped: %@", err]];
            else [me say:@"system" text:[NSString stringWithFormat:
                @"There is your %@ — it has opened in its own window. Edit it there, ask for "
                @"changes at the bottom, and save or print it when you are happy.",
                [spec.kind lowercaseString]]];
            if (done) done(text, err);
        }];
}

- (void)reviseDraft:(MVDraftWindow *)w instruction:(NSString *)ins
         completion:(void (^)(NSString *, NSString *))done {
    if (![self engineRunning]) {
        [w endGenerating];
        [self say:@"system" text:@"I need the model running before I can revise anything — press Start."];
        if (done) done(nil, @"the engine is not running");
        return;
    }
    if (self.busy) { if (done) done(nil, @"the model is already busy"); return; }

    NSString *current = [w bodyText];
    NSString *p = [NSString stringWithFormat:
        @"Below is a document, between the two rows of dashes.\n\n-----\n%@\n-----\n\n"
        @"Rewrite it with this change: %@\n\nReply with the complete rewritten document and "
        @"nothing else. No preamble, no summary of what you changed, and do not include the "
        @"rows of dashes. Keep everything the instruction does not ask you to change.",
        current, ins];

    [w beginGenerating:[NSString stringWithFormat:@"Revising: %@", ins]];
    [w setBodyText:@""];
    [self beginBusy];

    __weak AppDelegate *weakSelf = self;
    self.generation = [MVGeneration runWithMessages:[self messagesForPrompt:p]
        maxTokens:MAX(MVMaxReplyTokens(), 3072) temperature:MVTemperature() thinking:NO
        onDelta:^(NSString *content, NSString *reasoning) {
            if (content.length) [w appendDelta:content];
        }
        onDone:^(NSString *text, NSString *err, NSDictionary *timings) {
            AppDelegate *me = weakSelf; if (!me) return;
            me.generation = nil;
            if (!text.length && !err) [w setBodyText:current];   // never lose the user's draft
            else if (text.length) [w setBodyText:MVStripWrapper(text)];
            [w endGenerating];
            [me noteTimings:timings];
            [me endBusy];
            if (done) done(text, err);
        }];
}

#pragma mark Files opened from the Finder

- (BOOL)application:(NSApplication *)app openFile:(NSString *)filename {
    NSString *err = nil;
    if ([self attachDocumentAtPath:filename error:&err]) return YES;
    [self say:@"system" text:[NSString stringWithFormat:@"Could not read that file — %@", err]];
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)n { [[MVEngine shared] unload]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return NO; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *d = [AppDelegate new];
        app.delegate = d;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
