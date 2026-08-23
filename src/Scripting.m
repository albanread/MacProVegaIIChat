// Apple Event support.
//
// Everything the window can do, a script can do: start the engine, attach a
// document, review it, draft something, read the transcript back, and take a
// PNG of the window. That last one exists so the app can be checked from a
// script without anyone having to look at the screen.
//
// The commands that wait on the model suspend the Apple Event and resume it
// when the answer lands, so a script gets the real result rather than having to
// poll. AppleScript's own timeout still applies — wrap slow calls in
// "with timeout of 600 seconds".

#import "MacVega.h"

static AppDelegate *App(void) { return (AppDelegate *)NSApp.delegate; }

#pragma mark - Properties on the application object

@implementation NSApplication (MVScripting)

- (BOOL)scriptEngineRunning { return [App() engineRunning]; }
- (BOOL)scriptBusy          { return App().busy; }
- (NSString *)scriptStatus      { return [App() statusText]; }
- (NSString *)scriptTranscript  { return [App() transcriptText]; }
- (NSString *)scriptLastAnswer  { return App().lastAnswer ?: @""; }
- (NSString *)scriptModelName   { return [App() currentModelName] ?: @""; }
- (NSString *)scriptGPUName     { return App().gpuName ?: @""; }
- (NSString *)scriptAttachedDocument { return App().document.name ?: @""; }

- (NSString *)scriptDraftText {
    MVDraftWindow *w = [App() frontDraft];
    return w ? [w bodyText] : @"";
}
- (void)setScriptDraftText:(NSString *)t {
    MVDraftWindow *w = [App() frontDraft];
    if (w) [w setBodyText:t]; else [MVDraftWindow showWithTitle:@"Draft" text:t];
}
@end

#pragma mark - Waiting on a generation

// Shared tail for the commands that hand back model output.
@interface MVWaitingCommand : NSScriptCommand
@end

@implementation MVWaitingCommand
- (void)finishWith:(NSString *)result error:(NSString *)err {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (err) {
            self.scriptErrorNumber = -10000;
            self.scriptErrorString = err;
            [self resumeExecutionWithResult:nil];
        } else {
            [self resumeExecutionWithResult:result ?: @""];
        }
    });
}
- (BOOL)requireEngine {
    if ([App() engineRunning]) return YES;
    self.scriptErrorNumber = -10000;
    self.scriptErrorString = @"the model is not loaded yet — send “start engine” first, then “wait until ready”";
    return NO;
}
@end

#pragma mark - Engine

@interface MVStartCommand : NSScriptCommand @end
@implementation MVStartCommand
- (id)performDefaultImplementation {
    if ([App() engineRunning]) return @YES;
    [App() startEngine];
    return @(App().engineOn);
}
@end

@interface MVStopCommand : NSScriptCommand @end
@implementation MVStopCommand
- (id)performDefaultImplementation { [App() stopEngine]; return nil; }
@end

@interface MVNewChatCommand : NSScriptCommand @end
@implementation MVNewChatCommand
- (id)performDefaultImplementation { [App() startNewChat:nil]; return nil; }
@end

@interface MVSelectModelCommand : NSScriptCommand @end
@implementation MVSelectModelCommand
- (id)performDefaultImplementation {
    NSString *n = self.directParameter;
    if (![n isKindOfClass:[NSString class]] || !n.length) return @NO;
    return @([App() selectModelNamed:n]);
}
@end

// Polls rather than hooking the readiness path, because "ready" means two
// separate things here: the server answered /health, and nothing is generating.
@interface MVWaitCommand : NSScriptCommand
@property (assign) NSInteger deadline;
@end
@implementation MVWaitCommand
- (id)performDefaultImplementation {
    NSNumber *t = self.evaluatedArguments[@"timeout"];
    NSInteger secs = t ? MAX(1, t.integerValue) : 300;
    self.deadline = secs * 4;   // quarter-second ticks
    [self suspendExecution];
    [self tick];
    return nil;
}
- (void)tick {
    if ([App() engineRunning] && !App().busy) { [self resumeExecutionWithResult:@YES]; return; }
    if (--self.deadline <= 0) { [self resumeExecutionWithResult:@NO]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self tick]; });
}
@end

#pragma mark - Chat

@interface MVAskCommand : MVWaitingCommand @end
@implementation MVAskCommand
- (id)performDefaultImplementation {
    NSString *q = self.directParameter;
    if (![q isKindOfClass:[NSString class]] || !q.length) {
        self.scriptErrorNumber = -10000;
        self.scriptErrorString = @"nothing to ask";
        return nil;
    }
    if (![self requireEngine]) return nil;
    [self suspendExecution];
    [App() askQuestion:q completion:^(NSString *a, NSString *e) { [self finishWith:a error:e]; }];
    return nil;
}
@end

#pragma mark - Documents

@interface MVAttachCommand : NSScriptCommand @end
@implementation MVAttachCommand
- (id)performDefaultImplementation {
    NSString *path = self.directParameter;
    if (![path isKindOfClass:[NSString class]] || !path.length) {
        self.scriptErrorNumber = -10000;
        self.scriptErrorString = @"no path given";
        return nil;
    }
    NSString *err = nil;
    if (![App() attachDocumentAtPath:path error:&err]) {
        self.scriptErrorNumber = -10000;
        self.scriptErrorString = err ?: @"could not read that document";
        return nil;
    }
    return [App().document summaryLine];
}
@end

@interface MVDetachCommand : NSScriptCommand @end
@implementation MVDetachCommand
- (id)performDefaultImplementation { [App() detachDocument]; return nil; }
@end

static MVTask *MVTaskNamed(NSString *name) {
    NSString *n = [name.lowercaseString stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([n hasPrefix:@"sum"])                                    return [MVTask forKind:MVTaskSummarise];
    if ([n hasPrefix:@"key"] || [n hasPrefix:@"point"])          return [MVTask forKind:MVTaskKeyPoints];
    if ([n hasPrefix:@"crit"] || [n hasPrefix:@"rev"])           return [MVTask forKind:MVTaskCritique];
    if ([n hasPrefix:@"proof"] || [n hasPrefix:@"spell"])        return [MVTask forKind:MVTaskProofread];
    if ([n hasPrefix:@"action"] || [n hasPrefix:@"todo"])        return [MVTask forKind:MVTaskActions];
    if ([n hasPrefix:@"expl"] || [n hasPrefix:@"simpl"])         return [MVTask forKind:MVTaskExplain];
    return nil;
}

@interface MVReviewCommand : MVWaitingCommand @end
@implementation MVReviewCommand
- (id)performDefaultImplementation {
    if (![self requireEngine]) return nil;
    NSString *path = self.evaluatedArguments[@"document"];
    if ([path isKindOfClass:[NSString class]] && path.length) {
        NSString *err = nil;
        if (![App() attachDocumentAtPath:path error:&err]) {
            self.scriptErrorNumber = -10000;
            self.scriptErrorString = err ?: @"could not read that document";
            return nil;
        }
    }
    if (!App().document) {
        self.scriptErrorNumber = -10000;
        self.scriptErrorString = @"no document is attached";
        return nil;
    }
    NSString *want = self.directParameter;
    MVTask *task = [want isKindOfClass:[NSString class]] ? MVTaskNamed(want) : nil;
    if (!task) {
        // Anything we do not recognise is treated as a question about the document.
        task = [MVTask questionTask:([want isKindOfClass:[NSString class]] && want.length)
                                     ? want : @"What is this document about?"];
    }
    [self suspendExecution];
    [App() runTask:task onDocument:App().document
        completion:^(NSString *a, NSString *e) { [self finishWith:a error:e]; }];
    return nil;
}
@end

#pragma mark - Drafting

@interface MVWriteCommand : MVWaitingCommand @end
@implementation MVWriteCommand
- (id)performDefaultImplementation {
    if (![self requireEngine]) return nil;
    NSString *brief = self.directParameter;
    if (![brief isKindOfClass:[NSString class]] || !brief.length) {
        self.scriptErrorNumber = -10000;
        self.scriptErrorString = @"say what the document is for";
        return nil;
    }
    NSDictionary *args = self.evaluatedArguments;
    MVDraftSpec *spec = [MVDraftSpec new];
    spec.brief  = brief;
    spec.kind   = args[@"kind"]   ?: @"Anything";
    spec.tone   = args[@"tone"]   ?: @"Neutral";

    NSString *len = [args[@"length"] lowercaseString];
    spec.length = [len hasPrefix:@"s"] ? [MVDraftSpec lengths][0]
                : [len hasPrefix:@"l"] ? [MVDraftSpec lengths][2]
                                       : [MVDraftSpec lengths][1];

    if ([args[@"usingDocument"] boolValue] && App().document) {
        NSString *t = App().document.text;
        NSUInteger cap = (NSUInteger)((MVContextTokens() - 4000) * 3 * 0.7);
        spec.source = (t.length > cap) ? [t substringToIndex:cap] : t;
    }
    [self suspendExecution];
    [App() generateDraft:spec completion:^(NSString *a, NSString *e) { [self finishWith:a error:e]; }];
    return nil;
}
@end

@interface MVReviseCommand : MVWaitingCommand @end
@implementation MVReviseCommand
- (id)performDefaultImplementation {
    if (![self requireEngine]) return nil;
    MVDraftWindow *w = [App() frontDraft];
    if (!w) {
        self.scriptErrorNumber = -10000;
        self.scriptErrorString = @"there is no draft window open";
        return nil;
    }
    NSString *ins = self.directParameter;
    if (![ins isKindOfClass:[NSString class]] || !ins.length) {
        self.scriptErrorNumber = -10000;
        self.scriptErrorString = @"say what to change";
        return nil;
    }
    [self suspendExecution];
    [App() reviseDraft:w instruction:ins
            completion:^(NSString *a, NSString *e) { [self finishWith:a error:e]; }];
    return nil;
}
@end

#pragma mark - Panels

@interface MVPanelCommand : NSScriptCommand @end
@implementation MVPanelCommand
- (id)performDefaultImplementation {
    NSString *which = [self.directParameter isKindOfClass:[NSString class]]
                    ? [self.directParameter lowercaseString] : @"settings";
    if ([which hasPrefix:@"w"] || [which hasPrefix:@"d"]) [App() newDraft:nil];
    else [App() showSettings:nil];
    return nil;
}
@end

@interface MVClosePanelCommand : NSScriptCommand @end
@implementation MVClosePanelCommand
- (id)performDefaultImplementation {
    NSWindow *sheet = App().win.attachedSheet;
    if (sheet) [App().win endSheet:sheet];
    return nil;
}
@end

#pragma mark - Screenshot

@interface MVScreenshotCommand : NSScriptCommand @end
@implementation MVScreenshotCommand
- (id)performDefaultImplementation {
    NSString *path = self.directParameter;
    if (![path isKindOfClass:[NSString class]] || !path.length) {
        self.scriptErrorNumber = -10000;
        self.scriptErrorString = @"no path given";
        return nil;
    }
    NSString *which = [self.evaluatedArguments[@"window"] lowercaseString] ?: @"main";
    NSWindow *target = App().win;
    if ([which hasPrefix:@"sh"] || [which hasPrefix:@"se"] || [which hasPrefix:@"pa"]) {
        target = App().win.attachedSheet;
        if (!target) {
            self.scriptErrorNumber = -10000;
            self.scriptErrorString = @"no panel is open";
            return nil;
        }
    } else if ([which hasPrefix:@"dr"]) {
        MVDraftWindow *d = [App() frontDraft];
        if (!d) {
            self.scriptErrorNumber = -10000;
            self.scriptErrorString = @"there is no draft window open";
            return nil;
        }
        target = d.window;
    }
    NSError *e = nil;
    if (!MVWriteWindowPNG(target, path, &e)) {
        self.scriptErrorNumber = -10000;
        self.scriptErrorString = e.localizedDescription ?: @"could not write the screenshot";
        return nil;
    }
    return path.stringByExpandingTildeInPath;
}
@end
