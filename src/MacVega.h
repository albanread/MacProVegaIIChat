// Shared declarations for MacVegaII Chat.
//
// The app is split into:
//   main.m       window, engine process, chat
//   Engine.m     one streaming completion (MVGeneration)
//   DocText.m    reading text out of documents, and cutting it into chunks
//   Draft.m      the draft window
//   Scripting.m  Apple Event support (so the app can be automated and tested)

#import <Cocoa/Cocoa.h>

#pragma mark - Preferences (NSUserDefaults keys)

extern NSString *const MVPrefSystemPrompt;
extern NSString *const MVPrefTemperature;
extern NSString *const MVPrefContextTokens;
extern NSString *const MVPrefMaxReplyTokens;
extern NSString *const MVPrefCustomModelPath;
extern NSString *const MVPrefThinking;
extern NSString *const MVPrefShowThinking;
extern NSString *const MVPrefTextSize;
extern NSString *const MVPrefAutoStart;

NSInteger MVContextTokens(void);      // context window the engine is started with
NSInteger MVMaxReplyTokens(void);
double    MVTemperature(void);
NSString *MVSystemPrompt(void);       // "" when the user has not set one
BOOL      MVThinkingEnabled(void);    // let the model reason before answering
BOOL      MVShowThinking(void);       // keep the reasoning in the transcript
CGFloat   MVTextSize(void);           // transcript font size
BOOL      MVAutoStart(void);          // load the model as soon as the app opens

// "About 25 pages of text" for a token budget, and back again — the settings
// panel talks in pages because nobody thinks in tokens.
NSString *MVPagesForTokens(NSInteger tokens);

// Models like to hand a document back inside the fence you gave it in. Peel that
// off rather than making the user delete it.
NSString *MVStripWrapper(NSString *s);

#pragma mark - Documents

// Plain text out of whatever the user dropped on us: txt/md/source, pdf, rtf,
// doc(x), odt, html. Returns nil and fills *err if the file cannot be read.
NSString *MVExtractText(NSURL *url, NSError **err);
BOOL      MVCanReadDocument(NSURL *url);
NSArray<NSString *> *MVDocumentExtensions(void);

// Deliberately crude: good enough to keep clear of the context window.
NSInteger MVEstimateTokens(NSString *s);
NSInteger MVWordCount(NSString *s);

// Split on paragraph boundaries into pieces of at most maxChars.
NSArray<NSString *> *MVSplitIntoChunks(NSString *text, NSUInteger maxChars);

@interface MVDocument : NSObject
@property (copy)   NSString *name;      // "report.pdf"
@property (copy)   NSString *path;
@property (copy)   NSString *text;
@property (assign) NSInteger words;
@property (assign) NSInteger tokens;
@property (assign) BOOL      inContext; // small enough to sit in the conversation
+ (instancetype)fromURL:(NSURL *)url error:(NSError **)err;
- (NSString *)summaryLine;              // "report.pdf · 4,210 words · ~5,600 tokens"
@end

#pragma mark - Document tasks

typedef NS_ENUM(NSInteger, MVTaskKind) {
    MVTaskSummarise, MVTaskKeyPoints, MVTaskCritique,
    MVTaskProofread, MVTaskActions, MVTaskExplain, MVTaskQuestion,
};

@interface MVTask : NSObject
@property (assign) MVTaskKind kind;
@property (copy)   NSString *menuTitle;   // "Summarise it"
@property (copy)   NSString *instruction; // what we tell the model to do
@property (copy)   NSString *noteAsk;     // per-chunk instruction for long documents
@property (assign) BOOL      concatenate; // join the per-chunk answers instead of synthesising
+ (NSArray<MVTask *> *)all;
+ (MVTask *)forKind:(MVTaskKind)k;
+ (MVTask *)questionTask:(NSString *)question;
@end

#pragma mark - Drafting

@interface MVDraftSpec : NSObject
@property (copy) NSString *kind;    // "Letter", "Email", ...
@property (copy) NSString *brief;
@property (copy) NSString *tone;
@property (copy) NSString *length;
@property (copy) NSString *source;  // attached document text, or nil
- (NSString *)prompt;
+ (NSArray<NSString *> *)kinds;
+ (NSArray<NSString *> *)tones;
+ (NSArray<NSString *> *)lengths;
@end

#pragma mark - The model

typedef void (^MVDeltaBlock)(NSString *content, NSString *reasoning);
// timings carries prompt_n / predicted_n and the two speeds, or nil.
typedef void (^MVDoneBlock)(NSString *text, NSString *errorMessage, NSDictionary *timings);

// llama.cpp, linked in. One model, one context, one reply at a time.
@interface MVEngine : NSObject
+ (instancetype)shared;
@property (readonly) BOOL loaded;
@property (readonly, copy) NSString *modelName;
@property (readonly, copy) NSString *modelDescription;   // "qwen3moe 30B.A3B Q4_K - Medium"
@property (readonly) NSInteger contextTokens;            // what the context was actually opened at

// Straight from the model file. A GGUF carries its own chat template, and the
// family of that template decides both how turns are marked up and what a
// reasoning block looks like — <think> for Qwen3, [THINK] for Magistral,
// <|channel|>analysis<|message|> for gpt-oss. All of that comes from the file.
@property (readonly) BOOL modelHasOwnTemplate;   // NO means we fell back to ChatML
@property (readonly) BOOL modelCanThink;         // the template has a reasoning mode
@property (readonly, copy) NSString *chatFormatName;

// Compiling the Metal kernels takes about twenty seconds and happens the first
// time the backend is touched. Doing it at launch means pressing Start is only
// the weights. Safe to call more than once.
- (void)warmUpForDevice:(NSString *)gpu completion:(void (^)(double seconds))done;

- (void)loadModel:(NSString *)path
       deviceName:(NSString *)gpu
    contextTokens:(NSInteger)want
         progress:(void (^)(float fraction))progress
       completion:(void (^)(NSString *errorOrNil))done;
- (void)unload;
- (void)cancel;

// The real tokeniser, not a guess — used for the context meter and for deciding
// how much of a document fits in one pass.
- (NSInteger)countTokens:(NSString *)text;

- (void)generate:(NSArray *)messages
       maxTokens:(NSInteger)maxTokens
     temperature:(double)temperature
        thinking:(BOOL)thinking
         onDelta:(MVDeltaBlock)onDelta
          onDone:(MVDoneBlock)onDone;
@end

// A handle on the reply in progress, so it can be cancelled.
@interface MVGeneration : NSObject
@property (readonly, copy) NSString *text;
+ (instancetype)runWithMessages:(NSArray *)messages
                      maxTokens:(NSInteger)maxTokens
                    temperature:(double)temperature
                       thinking:(BOOL)thinking
                        onDelta:(MVDeltaBlock)onDelta
                         onDone:(MVDoneBlock)onDone;
- (void)cancel;
@end

#pragma mark - Draft window

@interface MVDraftWindow : NSWindowController
@property (copy) NSString *documentName;
+ (instancetype)showWithTitle:(NSString *)title text:(NSString *)text;
- (void)appendDelta:(NSString *)d;
- (void)setBodyText:(NSString *)t;
- (NSString *)bodyText;
- (void)beginGenerating:(NSString *)what;   // shows the spinner, disables editing
- (void)endGenerating;
@end

#pragma mark - App

@interface AppDelegate : NSObject <NSApplicationDelegate, NSURLSessionDownloadDelegate>

@property (strong) NSWindow *win;
@property (strong) NSPopUpButton *modelPop;
@property (strong) NSButton *actionBtn, *sendBtn, *stopBtn, *resetBtn;
@property (strong) NSProgressIndicator *prog;
@property (strong) NSTextField *status;
@property (strong) NSTextView *transcript;
@property (strong) NSTextView *input;

@property (assign) BOOL engineOn;      // the model is loaded, or on its way in
@property (strong) NSMutableArray *history;
@property (strong) MVDocument *document;
@property (strong) MVGeneration *generation;
@property (copy)   NSString *lastAnswer;
@property (assign) BOOL busy;
@property (copy)   NSString *gpuName;
@property (assign) double gpuVRAM;
@property (assign) BOOL gpuMetal3;

// Used by the scripting commands and by the draft window.
- (BOOL)engineRunning;
- (BOOL)selectedModelPresent;
- (void)startDownload;
@property (copy) void (^downloadDone)(BOOL ok, NSString *error);
- (void)startEngine;
- (void)stopEngine;
- (NSInteger)tokensIn:(NSString *)s;
- (void)startNewChat:(id)sender;
- (void)say:(NSString *)role text:(NSString *)t;
- (void)showStatus:(NSString *)s;
- (NSString *)statusText;
- (NSString *)transcriptText;
- (BOOL)selectModelNamed:(NSString *)name;
- (NSString *)currentModelName;

// Asks a question in the chat window exactly as if it had been typed.
- (void)askQuestion:(NSString *)q completion:(void (^)(NSString *answer, NSString *err))done;
// Reads a document and runs a task over it, streaming into the transcript.
- (void)runTask:(MVTask *)task onDocument:(MVDocument *)doc
     completion:(void (^)(NSString *answer, NSString *err))done;
- (BOOL)attachDocumentAtPath:(NSString *)path error:(NSString **)err;
- (void)detachDocument;
- (void)generateDraft:(MVDraftSpec *)spec completion:(void (^)(NSString *text, NSString *err))done;
- (void)reviseDraft:(MVDraftWindow *)w instruction:(NSString *)ins completion:(void (^)(NSString *text, NSString *err))done;
- (MVDraftWindow *)frontDraft;

// Messages for a one-off request, with the system prompt applied.
- (NSArray *)messagesForPrompt:(NSString *)prompt;
@end

// Implemented in Sheets.m.
@interface AppDelegate (Sheets)
- (void)showSettings:(id)sender;
- (void)newDraft:(id)sender;
@end

// Light Markdown rendering: headings, bullets, bold, italic, inline code and
// fenced code. Used for the transcript and for RTF/Word export.
NSAttributedString *MVRenderMarkdown(NSString *src, CGFloat bodySize);

// Renders the main window (or a draft window) into a PNG. Nothing is captured
// off-screen, so this needs no screen-recording permission.
BOOL MVWriteWindowPNG(NSWindow *win, NSString *path, NSError **err);
