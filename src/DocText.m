// Getting plain text out of the things people actually have on disk, and the
// small amount of bookkeeping that goes with it.

#import "MacVega.h"
#import <PDFKit/PDFKit.h>

#pragma mark - Preferences

NSString *const MVPrefSystemPrompt    = @"SystemPrompt";
NSString *const MVPrefTemperature     = @"Temperature";
NSString *const MVPrefContextTokens   = @"ContextTokens";
NSString *const MVPrefMaxReplyTokens  = @"MaxReplyTokens";
NSString *const MVPrefCustomModelPath = @"CustomModelPath";
NSString *const MVPrefThinking        = @"Thinking";
NSString *const MVPrefShowThinking    = @"ShowThinking";
NSString *const MVPrefTextSize        = @"TextSize";
NSString *const MVPrefAutoStart       = @"AutoStart";

static void MVRegisterDefaults(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            MVPrefSystemPrompt:   @"",
            MVPrefTemperature:    @0.7,
            MVPrefContextTokens:  @16384,
            MVPrefMaxReplyTokens: @4096,
            MVPrefThinking:       @YES,
            MVPrefShowThinking:   @NO,
            MVPrefTextSize:       @13,
            MVPrefAutoStart:      @NO,
        }];
    });
}
NSInteger MVContextTokens(void) {
    MVRegisterDefaults();
    NSInteger v = [[NSUserDefaults standardUserDefaults] integerForKey:MVPrefContextTokens];
    return v > 0 ? v : 16384;
}
NSInteger MVMaxReplyTokens(void) {
    MVRegisterDefaults();
    NSInteger v = [[NSUserDefaults standardUserDefaults] integerForKey:MVPrefMaxReplyTokens];
    return v > 0 ? v : 4096;
}
double MVTemperature(void) {
    MVRegisterDefaults();
    return [[NSUserDefaults standardUserDefaults] doubleForKey:MVPrefTemperature];
}
BOOL MVThinkingEnabled(void) {
    MVRegisterDefaults();
    return [[NSUserDefaults standardUserDefaults] boolForKey:MVPrefThinking];
}
BOOL MVShowThinking(void) {
    MVRegisterDefaults();
    return [[NSUserDefaults standardUserDefaults] boolForKey:MVPrefShowThinking];
}
CGFloat MVTextSize(void) {
    MVRegisterDefaults();
    CGFloat v = [[NSUserDefaults standardUserDefaults] doubleForKey:MVPrefTextSize];
    return (v >= 10 && v <= 24) ? v : 13;
}
BOOL MVAutoStart(void) {
    MVRegisterDefaults();
    return [[NSUserDefaults standardUserDefaults] boolForKey:MVPrefAutoStart];
}

// A page of prose is roughly 500 words, and a word is roughly 1.3 tokens.
NSString *MVPagesForTokens(NSInteger tokens) {
    NSInteger pages = MAX(1, (NSInteger) lround(tokens / 650.0));
    return [NSString stringWithFormat:@"about %ld page%@ of text", (long)pages, pages == 1 ? @"" : @"s"];
}

NSString *MVStripWrapper(NSString *s) {
    NSMutableArray<NSString *> *lines =
        [[s componentsSeparatedByString:@"\n"] mutableCopy];
    BOOL (^fence)(NSString *) = ^BOOL(NSString *l) {
        NSString *t = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length < 3) return NO;
        if ([t hasPrefix:@"```"]) return YES;
        return [[t stringByReplacingOccurrencesOfString:@"-" withString:@""] length] == 0;
    };
    while (lines.count && ![lines[0] stringByTrimmingCharactersInSet:
           [NSCharacterSet whitespaceCharacterSet]].length) [lines removeObjectAtIndex:0];
    if (lines.count && fence(lines[0])) [lines removeObjectAtIndex:0];
    while (lines.count && ![lines.lastObject stringByTrimmingCharactersInSet:
           [NSCharacterSet whitespaceCharacterSet]].length) [lines removeLastObject];
    if (lines.count && fence(lines.lastObject)) [lines removeLastObject];
    return [[lines componentsJoinedByString:@"\n"]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

NSString *MVSystemPrompt(void) {
    MVRegisterDefaults();
    NSString *s = [[NSUserDefaults standardUserDefaults] stringForKey:MVPrefSystemPrompt];
    return s ?: @"";
}

#pragma mark - Counting

NSInteger MVEstimateTokens(NSString *s) { return (NSInteger)(s.length / 3) + 1; }

NSInteger MVWordCount(NSString *s) {
    if (!s.length) return 0;
    __block NSInteger n = 0;
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length)
                          options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired
                       usingBlock:^(NSString *w, NSRange r1, NSRange r2, BOOL *stop) { n++; }];
    return n;
}

#pragma mark - Reading documents

NSArray<NSString *> *MVDocumentExtensions(void) {
    return @[@"txt", @"text", @"md", @"markdown", @"rst", @"log", @"csv", @"tsv", @"json", @"xml",
             @"pdf", @"rtf", @"rtfd", @"doc", @"docx", @"odt", @"html", @"htm",
             @"c", @"h", @"m", @"mm", @"cpp", @"cc", @"hpp", @"py", @"js", @"ts", @"swift",
             @"sh", @"zsh", @"rb", @"go", @"rs", @"java", @"sql", @"yaml", @"yml", @"toml",
             @"ini", @"conf", @"tex", @"srt", @"vtt"];
}

BOOL MVCanReadDocument(NSURL *url) {
    NSString *e = url.pathExtension.lowercaseString;
    return e.length == 0 || [MVDocumentExtensions() containsObject:e];
}

static NSString *MVTextFromAttributed(NSURL *url, NSError **err) {
    NSDictionary *opts = @{NSDocumentTypeDocumentAttribute: NSPlainTextDocumentType};
    NSAttributedString *a = [[NSAttributedString alloc] initWithURL:url
                                                           options:@{}
                                                documentAttributes:nil
                                                             error:err];
    (void)opts;
    return a.string;
}

static NSString *MVTextFromPlainFile(NSURL *url, NSError **err) {
    NSData *d = [NSData dataWithContentsOfURL:url options:0 error:err];
    if (!d) return nil;
    // Reject binaries early rather than filling the window with mojibake.
    NSUInteger probe = MIN(d.length, (NSUInteger)4096);
    const unsigned char *b = d.bytes;
    for (NSUInteger i = 0; i < probe; i++) {
        if (b[i] == 0) {
            if (err) *err = [NSError errorWithDomain:@"MacVegaIIChat" code:2 userInfo:@{
                NSLocalizedDescriptionKey: @"that looks like a binary file, not a document"}];
            return nil;
        }
    }
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    if (!s && err) *err = [NSError errorWithDomain:@"MacVegaIIChat" code:3 userInfo:@{
        NSLocalizedDescriptionKey: @"could not work out the text encoding of that file"}];
    return s;
}

NSString *MVExtractText(NSURL *url, NSError **err) {
    NSString *ext = url.pathExtension.lowercaseString;

    if ([ext isEqualToString:@"pdf"]) {
        PDFDocument *pdf = [[PDFDocument alloc] initWithURL:url];
        if (!pdf) {
            if (err) *err = [NSError errorWithDomain:@"MacVegaIIChat" code:4 userInfo:@{
                NSLocalizedDescriptionKey: @"that PDF could not be opened"}];
            return nil;
        }
        NSMutableString *out = [NSMutableString string];
        for (NSUInteger i = 0; i < pdf.pageCount; i++) {
            NSString *p = [[pdf pageAtIndex:i] string];
            if (p.length) { [out appendString:p]; [out appendString:@"\n\n"]; }
        }
        if (!out.length && err) *err = [NSError errorWithDomain:@"MacVegaIIChat" code:5 userInfo:@{
            NSLocalizedDescriptionKey: @"that PDF has no selectable text — it is probably a scan, "
                                       @"and this app cannot read images"}];
        return out.length ? out : nil;
    }

    if ([@[@"rtf", @"rtfd", @"doc", @"docx", @"odt", @"html", @"htm", @"webarchive"] containsObject:ext])
        return MVTextFromAttributed(url, err);

    return MVTextFromPlainFile(url, err);
}

#pragma mark - Chunking

// Cut on paragraph boundaries where possible: a chunk that ends mid-sentence
// makes the model summarise half a thought.
NSArray<NSString *> *MVSplitIntoChunks(NSString *text, NSUInteger maxChars) {
    NSMutableArray *out = [NSMutableArray array];
    if (text.length <= maxChars) { if (text.length) [out addObject:text]; return out; }

    NSArray *paras = [text componentsSeparatedByString:@"\n\n"];
    NSMutableString *cur = [NSMutableString string];
    for (NSString *p0 in paras) {
        NSString *p = p0;
        while (p.length > maxChars) {
            // A single monstrous paragraph: fall back to cutting at a line break
            // near the limit, and to a hard cut if there is not one.
            NSRange win = NSMakeRange(maxChars * 3 / 4, maxChars / 4);
            NSRange nl = [p rangeOfString:@"\n" options:NSBackwardsSearch range:win];
            NSUInteger cut = (nl.location != NSNotFound) ? nl.location + 1 : maxChars;
            if (cur.length) { [out addObject:[cur copy]]; cur = [NSMutableString string]; }
            [out addObject:[p substringToIndex:cut]];
            p = [p substringFromIndex:cut];
        }
        if (cur.length + p.length + 2 > maxChars && cur.length) {
            [out addObject:[cur copy]];
            cur = [NSMutableString string];
        }
        if (cur.length) [cur appendString:@"\n\n"];
        [cur appendString:p];
    }
    if (cur.length) [out addObject:[cur copy]];
    return out;
}

#pragma mark - MVDocument

@implementation MVDocument

+ (instancetype)fromURL:(NSURL *)url error:(NSError **)err {
    NSString *t = MVExtractText(url, err);
    if (!t) return nil;
    t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) {
        if (err) *err = [NSError errorWithDomain:@"MacVegaIIChat" code:6 userInfo:@{
            NSLocalizedDescriptionKey: @"there is no text in that file"}];
        return nil;
    }
    MVDocument *d = [MVDocument new];
    d.name = url.lastPathComponent;
    d.path = url.path;
    d.text = t;
    d.words = MVWordCount(t);
    d.tokens = MVEstimateTokens(t);
    return d;
}

- (NSString *)summaryLine {
    NSNumberFormatter *f = [NSNumberFormatter new];
    f.numberStyle = NSNumberFormatterDecimalStyle;
    return [NSString stringWithFormat:@"%@  ·  %@ words", self.name,
            [f stringFromNumber:@(self.words)]];
}
@end

#pragma mark - Tasks

@implementation MVTask

+ (MVTask *)k:(MVTaskKind)k title:(NSString *)title ins:(NSString *)ins note:(NSString *)note cat:(BOOL)cat {
    MVTask *t = [MVTask new];
    t.kind = k; t.menuTitle = title; t.instruction = ins; t.noteAsk = note; t.concatenate = cat;
    return t;
}

+ (NSArray<MVTask *> *)all {
    // These read fussily, and that is deliberate. Asked for "wrong → right" without a
    // worked example, the model copies the words "wrong → right" into its answer; asked
    // without "never write a line where both sides are the same", it pads the list with
    // corrections that correct nothing.
    return @[
    [self k:MVTaskSummarise title:@"Summarise it"
          ins:@"Summarise the document for a busy reader. Open with the single most important "
              @"point in one sentence, then give three to six bullets covering the rest. "
              @"Stay under 250 words. Do not invent anything that is not in the document."
         note:@"Write compact notes on this part of a longer document: the points a summary "
              @"of the whole would need. Bullets only, no preamble."
          cat:NO],

    [self k:MVTaskKeyPoints title:@"Pull out the key points"
          ins:@"List the key points of the document as bullets, in the order they appear. "
              @"One sentence each. Keep every figure, date and name that matters. "
              @"No introduction and no conclusion — just the list."
         note:@"List the key points in this part of a longer document as bullets, keeping "
              @"any figures, dates and names."
          cat:NO],

    [self k:MVTaskCritique title:@"Review and critique it"
          ins:@"Review the document as a careful editor would. Use these four headings: "
              @"What works, What is unclear, What is missing, What could be cut. Under each, "
              @"give bullets, quoting a short phrase from the document when you refer to "
              @"something specific. Be concrete and kind — the aim is a better draft, not a "
              @"verdict."
         note:@"You are reviewing one part of a longer document. Note the editorial "
              @"observations worth carrying into a review of the whole: strengths, unclear "
              @"or unsupported passages, gaps, and padding. Quote short phrases."
          cat:NO],

    [self k:MVTaskProofread title:@"Proofread it"
          ins:@"Proofread the document. Give one line for each mistake you find, in this "
              @"form:\n\n    dont → don't   (\"dont just prop the door open\")\n\n"
              @"The left side is the text as written, the right side is the correction, and "
              @"the quotation locates it. Never write a line where both sides are the same — "
              @"if something is already correct, leave it out. Cover spelling, grammar, "
              @"punctuation and consistency only: do not rewrite the document and do not "
              @"comment on style. If you find no mistakes, reply with one line: "
              @"No mistakes found."
         note:@"Proofread this part of a document. Give one line per mistake, in this form:"
              @"\n\n    dont → don't   (\"dont just prop the door open\")\n\n"
              @"Never write a line where both sides are the same. If there is nothing wrong "
              @"in this part, reply with just: (nothing in this part)"
          cat:YES],

    [self k:MVTaskActions title:@"Extract the action items"
          ins:@"List every action, decision, commitment and deadline in the document. One per "
              @"line, in this form:\n\n    Priya — electrical sign-off — Monday morning\n\n"
              @"Write “unassigned” where no one is named and “no date” where none is given. "
              @"If there are none, reply with one line: Nothing to do."
         note:@"From this part of a longer document, list every action, decision, commitment "
              @"and deadline, one per line, in this form:\n\n"
              @"    Priya — electrical sign-off — Monday morning\n\n"
              @"Reply “(none in this part)” if there are none."
          cat:NO],

    [self k:MVTaskExplain title:@"Explain it simply"
          ins:@"Explain what this document says in plain English, as if to a capable person "
              @"who does not know the subject. Define any jargon the first time you use it. "
              @"Six short paragraphs at most."
         note:@"Explain in plain English what this part of a longer document says, defining "
              @"any jargon. Compact notes, not prose."
          cat:NO],
    ];
}

+ (MVTask *)forKind:(MVTaskKind)k {
    for (MVTask *t in [self all]) if (t.kind == k) return t;
    return [self all][0];
}

+ (MVTask *)questionTask:(NSString *)question {
    MVTask *t = [MVTask new];
    t.kind = MVTaskQuestion;
    t.menuTitle = @"Question";
    t.instruction = [NSString stringWithFormat:
        @"Answer this question about the document: %@\n\nUse only what the document says. "
        @"If it does not say, reply that it does not say.", question];
    t.noteAsk = [NSString stringWithFormat:
        @"From this part of a longer document, note anything relevant to the question: %@\n"
        @"If nothing here is relevant, reply “(nothing relevant in this part)”.", question];
    t.concatenate = NO;
    return t;
}
@end

#pragma mark - Drafting

@implementation MVDraftSpec

+ (NSArray<NSString *> *)kinds {
    return @[@"Letter", @"Email", @"Memo", @"Report", @"Proposal", @"Blog post",
             @"Meeting notes", @"Instructions", @"Press release", @"Anything"];
}
+ (NSArray<NSString *> *)tones {
    return @[@"Neutral", @"Friendly", @"Formal", @"Direct", @"Warm", @"Persuasive"];
}
+ (NSArray<NSString *> *)lengths {
    return @[@"Short (a few paragraphs)", @"Medium (about a page)", @"Long (several pages)"];
}

- (NSString *)prompt {
    NSString *lengthHint = [self.length hasPrefix:@"Short"]  ? @"roughly 150–250 words"
                         : [self.length hasPrefix:@"Long"]   ? @"roughly 900–1400 words"
                                                             : @"roughly 400–600 words";
    NSMutableString *p = [NSMutableString string];
    [p appendFormat:@"Write a %@ in a %@ tone, %@.\n\n",
        [self.kind isEqualToString:@"Anything"] ? @"document" : [self.kind lowercaseString],
        [self.tone lowercaseString], lengthHint];
    [p appendFormat:@"What it is for:\n%@\n\n", self.brief];
    if (self.source.length)
        [p appendFormat:
            @"Here is source material. Take the facts from it — names, dates, places, "
            @"decisions — and do not contradict it. Do NOT reproduce it: what you write is a "
            @"new and different document, for the purpose given above, not a rewrite of this "
            @"one.\n-----\n%@\n-----\n\n", self.source];
    [p appendString:
        @"Return only the document itself in Markdown: no preamble, no explanation of your "
        @"choices, no closing offer to revise it.\n\nIf a detail the document needs is "
        @"genuinely unknown to you, write it as [in square brackets] so it is obvious what "
        @"has to be filled in. Never bracket a detail you have been given — if a date, a name "
        @"or a figure appears above, use it as it stands."];
    return p;
}
@end
