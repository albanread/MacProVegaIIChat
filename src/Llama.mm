// llama.cpp, linked in.
//
// This used to spawn llama-server and talk HTTP to it on the loopback. The
// library is now linked straight into the app, which removes the whole class of
// problems that came with owning a second process: no ports, no /health poll, no
// engine left running in VRAM when the app is killed. It also means the model
// stays loaded exactly as long as the app does, and cancelling a reply is a flag
// rather than a socket close.
//
// Everything here runs on one serial queue. llama_decode is not re-entrant, and
// a single queue is both the simplest way to guarantee that and a natural fit:
// there is one model, one context, and one reply at a time.

#import "MacVega.h"

#include "llama.h"
#include "ggml-backend.h"
#include "chat.h"

#include <atomic>
#include <string>
#include <vector>

#pragma mark - Small conveniences

static std::string MVStr(NSString *s) { return s.length ? std::string(s.UTF8String) : std::string(); }

// A token can end mid-character. Emitting that as an NSString gives nil, so
// only hand over the part of the buffer that is complete UTF-8.
static size_t MVCompleteUTF8Length(const std::string & s) {
    size_t n = s.size();
    size_t back = 0;
    while (back < 4 && back < n) {
        unsigned char c = (unsigned char) s[n - 1 - back];
        if ((c & 0xC0) != 0x80) {                     // start of a character
            size_t need = (c < 0x80) ? 1 : (c >> 5) == 0x6 ? 2 : (c >> 4) == 0xE ? 3 : (c >> 3) == 0x1E ? 4 : 1;
            return (back + 1 >= need) ? n : n - back - 1;
        }
        back++;
    }
    return n;
}

static NSString *MVNS(const std::string & s) {
    NSString *r = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    return r ?: @"";
}

#pragma mark - Log capture

// llama.cpp says why a model failed to load on its log, and nowhere else. Keep
// the tail so the window can show a real reason instead of "it did not work".
static std::vector<std::string> g_logTail;
static NSString *MVLastErrorLine(void) {
    for (auto it = g_logTail.rbegin(); it != g_logTail.rend(); ++it) {
        if (it->find("error") != std::string::npos || it->find("failed") != std::string::npos)
            return MVNS(*it);
    }
    return g_logTail.empty() ? @"" : MVNS(g_logTail.back());
}
static void MVLogCallback(enum ggml_log_level level, const char * text, void * user) {
    (void) user;
    if (!text) return;
    if (level == GGML_LOG_LEVEL_ERROR || level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_INFO) {
        std::string s(text);
        while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
        if (!s.empty()) {
            g_logTail.push_back(s);
            if (g_logTail.size() > 64) g_logTail.erase(g_logTail.begin());
        }
    }
    fputs(text, stderr);
}

#pragma mark - MVEngine

@implementation MVEngine {
    llama_model              *_model;
    llama_context            *_ctx;
    const llama_vocab        *_vocab;
    common_chat_templates_ptr _tmpls;
    std::vector<llama_token>  _cached;       // what is currently in the KV cache
    dispatch_queue_t          _q;
    std::atomic<bool>         _cancel;
    std::atomic<bool>         _abortLoad;
    void (^_progress)(float);
    NSLock                   *_vocabLock;
}

+ (instancetype)shared {
    static MVEngine *e;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ e = [MVEngine new]; });
    return e;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("com.albanread.macvegaiichat.llama", DISPATCH_QUEUE_SERIAL);
        _cancel = false;
        _abortLoad = false;
        _vocabLock = [NSLock new];
    }
    return self;
}

- (BOOL)loaded { return _model != NULL && _ctx != NULL; }

static bool MVProgressThunk(float p, void * user) {
    MVEngine *e = (__bridge MVEngine *) user;
    return [e reportLoadProgress:p];
}
- (BOOL)reportLoadProgress:(float)p {
    void (^cb)(float) = _progress;
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(p); });
    return !_abortLoad.load();
}

// The kernels are compiled from source at runtime, with the SIMD width of the
// card baked in as a macro — which is the whole point on a wave64 AMD part, and
// why a precompiled .metallib cannot be shipped instead. It costs about twenty
// seconds. Spending them while the user is still reading the welcome text is
// better than spending them after they press Start.
- (void)startBackendForDevice:(NSString *)gpu {
    if (gpu.length) setenv("GGML_METAL_DEVICE", gpu.UTF8String, 1);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        llama_log_set(MVLogCallback, NULL);
        llama_backend_init();
        // touching the registry is what actually builds the Metal device and
        // compiles the library; llama_backend_init alone may not
        (void) ggml_backend_dev_count();
    });
}

- (void)warmUpForDevice:(NSString *)gpu completion:(void (^)(double))done {
    NSString *g = [gpu copy];
    void (^fin)(double) = [done copy];
    dispatch_async(_q, ^{
        NSDate *t0 = [NSDate date];
        [self startBackendForDevice:g];
        double secs = -[t0 timeIntervalSinceNow];
        dispatch_async(dispatch_get_main_queue(), ^{ if (fin) fin(secs); });
    });
}

- (void)loadModel:(NSString *)path
       deviceName:(NSString *)gpu
    contextTokens:(NSInteger)want
         progress:(void (^)(float))progress
       completion:(void (^)(NSString *error))done {
    NSString *p = [path copy], *g = [gpu copy];
    void (^prog)(float) = [progress copy];
    void (^fin)(NSString *) = [done copy];

    dispatch_async(_q, ^{
        [self teardown];
        self->_abortLoad = false;
        self->_progress = prog;

        // The fork reads this at Metal device init. On a Mac Pro the system default
        // device is whichever GPU drives the display, which is usually not the one
        // you want doing the arithmetic.
        [self startBackendForDevice:g];
        g_logTail.clear();

        llama_model_params mp = llama_model_default_params();
        mp.n_gpu_layers = 999;                  // all of it on the GPU
        mp.load_mode    = LLAMA_LOAD_MODE_NONE; // resident in VRAM: mmap here is ~16x slower
        mp.progress_callback = MVProgressThunk;
        mp.progress_callback_user_data = (__bridge void *) self;

        self->_model = llama_model_load_from_file(p.UTF8String, mp);
        self->_progress = nil;
        if (!self->_model) {
            NSString *why = self->_abortLoad.load() ? @"cancelled" : MVLastErrorLine();
            dispatch_async(dispatch_get_main_queue(), ^{
                if (fin) fin(why.length ? why : @"the model could not be loaded");
            });
            return;
        }

        NSInteger trained = llama_model_n_ctx_train(self->_model);
        NSInteger nctx = want > 0 ? want : 16384;
        if (trained > 0 && nctx > trained) nctx = trained;

        llama_context_params cp = llama_context_default_params();
        cp.n_ctx           = (uint32_t) nctx;
        cp.n_batch         = 2048;   // same shape as llama-server's defaults
        cp.n_ubatch        = 512;
        cp.n_threads       = (int32_t) MAX(1, (NSInteger)[NSProcessInfo processInfo].activeProcessorCount / 2);
        cp.n_threads_batch = cp.n_threads;

        self->_ctx = llama_init_from_model(self->_model, cp);
        if (!self->_ctx) {
            llama_model_free(self->_model);
            self->_model = NULL;
            NSString *why = MVLastErrorLine();
            dispatch_async(dispatch_get_main_queue(), ^{
                if (fin) fin(why.length ? why : @"there was not enough memory for that context size");
            });
            return;
        }

        [self->_vocabLock lock];
        self->_vocab = llama_model_get_vocab(self->_model);
        [self->_vocabLock unlock];

        // "" as the override means: use the template the model file carries.
        // Anything else would be second-guessing the people who trained it.
        try {
            self->_tmpls = common_chat_templates_init(self->_model, "");
        } catch (const std::exception & e) {
            [self teardown];
            NSString *why = MVNS(std::string("its chat template will not parse: ") + e.what());
            dispatch_async(dispatch_get_main_queue(), ^{ if (fin) fin(why); });
            return;
        }
        self->_modelHasOwnTemplate = common_chat_templates_was_explicit(self->_tmpls.get());

        // Render one throwaway turn now, so a template that only breaks when used
        // breaks here rather than on the user's first message. It also tells us
        // whether this model has a reasoning mode at all.
        {
            common_chat_templates_inputs probe;
            common_chat_msg hello;
            hello.role = "user";
            hello.content = "hello";
            probe.messages.push_back(hello);
            probe.add_generation_prompt = true;
            probe.use_jinja = true;
            try {
                common_chat_params cp = common_chat_templates_apply(self->_tmpls.get(), probe);
                self->_modelCanThink = cp.supports_thinking;
                self->_chatFormatName = MVNS(std::string(common_chat_format_name(cp.format)));
            } catch (const std::exception & e) {
                [self teardown];
                NSString *why = MVNS(std::string("its chat template will not run: ") + e.what());
                dispatch_async(dispatch_get_main_queue(), ^{ if (fin) fin(why); });
                return;
            }
        }
        self->_cached.clear();
        self->_modelName = p.lastPathComponent;
        self->_contextTokens = (NSInteger) llama_n_ctx(self->_ctx);

        char desc[256] = {0};
        llama_model_desc(self->_model, desc, sizeof desc);
        self->_modelDescription = MVNS(std::string(desc));

        dispatch_async(dispatch_get_main_queue(), ^{ if (fin) fin(nil); });
    });
}

- (void)teardown {
    [_vocabLock lock];
    _vocab = NULL;
    [_vocabLock unlock];
    _tmpls.reset();
    if (_ctx)   { llama_free(_ctx);         _ctx   = NULL; }
    if (_model) { llama_model_free(_model); _model = NULL; }
    _cached.clear();
    _modelName = nil;
    _modelDescription = nil;
    _chatFormatName = nil;
    _contextTokens = 0;
    _modelHasOwnTemplate = NO;
    _modelCanThink = NO;
}

- (void)unload {
    _abortLoad = true;
    _cancel = true;
    dispatch_async(_q, ^{ [self teardown]; });
}

- (void)cancel { _cancel = true; }

// Exact token count, which is what the context meter and the document splitter
// want — the old chars/3 guess was out by a third on anything with punctuation.
- (NSInteger)countTokens:(NSString *)text {
    if (!text.length) return 0;
    [_vocabLock lock];
    const llama_vocab *v = _vocab;
    int32_t n = 0;
    if (v) {
        std::string s = MVStr(text);
        n = -llama_tokenize(v, s.data(), (int32_t) s.size(), NULL, 0, false, true);
    }
    [_vocabLock unlock];
    return n > 0 ? n : (NSInteger)(text.length / 3);
}

#pragma mark Generation

- (void)generate:(NSArray *)messages
       maxTokens:(NSInteger)maxTokens
     temperature:(double)temperature
        thinking:(BOOL)thinking
         onDelta:(MVDeltaBlock)onDelta
          onDone:(MVDoneBlock)onDone {
    NSArray *msgs = [messages copy];
    MVDeltaBlock delta = [onDelta copy];
    MVDoneBlock done = [onDone copy];

    dispatch_async(_q, ^{
        self->_cancel = false;
        if (![self loaded]) {
            if (done) done(@"", @"the model is not loaded", nil);
            return;
        }

        // --- prompt ------------------------------------------------------
        common_chat_templates_inputs in;
        for (NSDictionary *m in msgs) {
            common_chat_msg cm;
            cm.role    = MVStr(m[@"role"]);
            cm.content = MVStr(m[@"content"]);
            in.messages.push_back(cm);
        }
        in.add_generation_prompt = true;
        in.use_jinja             = true;
        in.enable_thinking       = thinking ? true : false;
        in.chat_template_kwargs["enable_thinking"] = thinking ? "true" : "false";

        common_chat_params cp;
        try {
            cp = common_chat_templates_apply(self->_tmpls.get(), in);
        } catch (const std::exception & e) {
            if (done) done(@"", MVNS(std::string("chat template: ") + e.what()), nil);
            return;
        }

        std::vector<llama_token> toks;
        {
            const std::string & s = cp.prompt;
            int32_t n = -llama_tokenize(self->_vocab, s.data(), (int32_t) s.size(), NULL, 0, true, true);
            toks.resize(n > 0 ? n : 0);
            if (n > 0) llama_tokenize(self->_vocab, s.data(), (int32_t) s.size(), toks.data(), n, true, true);
        }
        const uint32_t nctx = llama_n_ctx(self->_ctx);
        if (toks.size() + 16 >= nctx) {
            if (done) done(@"", @"that is longer than the model can hold at once", nil);
            return;
        }

        // --- reuse whatever of the prompt is already in the cache ---------
        // Keeping the prefix is the difference between a follow-up question taking
        // a second and taking half a minute, so the conversation is only ever
        // appended to; trimming from the front is done sparingly and knowingly.
        size_t reuse = 0;
        while (reuse < self->_cached.size() && reuse < toks.size() && self->_cached[reuse] == toks[reuse]) reuse++;
        if (reuse == toks.size() && reuse > 0) reuse--;   // always leave one to decode
        llama_memory_t mem = llama_get_memory(self->_ctx);
        if (!llama_memory_seq_rm(mem, 0, (llama_pos) reuse, -1)) {
            // A partial removal that cannot be honoured would leave the positions
            // out of step with what we think is cached. Start clean instead.
            llama_memory_seq_rm(mem, 0, -1, -1);
            reuse = 0;
        }
        self->_cached.resize(reuse);

        NSDate *t0 = [NSDate date];
        const int32_t nb = 2048;
        for (size_t i = reuse; i < toks.size(); i += nb) {
            if (self->_cancel.load()) { if (done) done(@"", nil, nil); return; }
            int32_t n = (int32_t) MIN((size_t) nb, toks.size() - i);
            llama_batch b = llama_batch_get_one(toks.data() + i, n);
            if (llama_decode(self->_ctx, b) != 0) {
                self->_cached.clear();
                llama_memory_seq_rm(mem, 0, 0, -1);
                if (done) done(@"", @"the model could not process that prompt", nil);
                return;
            }
            self->_cached.insert(self->_cached.end(), toks.begin() + i, toks.begin() + i + n);
        }
        const double promptSecs = -[t0 timeIntervalSinceNow];
        const size_t nPrompt = toks.size() - reuse;

        // --- sample -------------------------------------------------------
        auto sparams = llama_sampler_chain_default_params();
        sparams.no_perf = true;
        llama_sampler *smpl = llama_sampler_chain_init(sparams);
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40));
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.95f, 1));
        llama_sampler_chain_add(smpl, llama_sampler_init_temp((float) temperature));
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

        std::string answer;      // the content, with any thinking removed
        std::string pending;     // decoded but not yet classified
        bool inThink = false;
        // If the template has no reasoning mode there is nothing to look for, and
        // scanning for a tag that never arrives only delays the last few characters.
        bool thinkDone = !thinking || !cp.supports_thinking;
        const std::string startTag = cp.thinking_start_tag.empty() ? std::string("<think>") : cp.thinking_start_tag;
        std::vector<std::string> endTags = cp.thinking_end_tags;
        if (endTags.empty()) endTags.push_back("</think>");
        size_t maxEnd = 0;
        for (auto & e : endTags) maxEnd = MAX(maxEnd, e.size());

        NSDate *t1 = [NSDate date];
        size_t nGen = 0;
        NSString *err = nil;

        // Hands finished text to the caller, holding back anything that might yet
        // turn out to be the first half of a <think> tag.
        auto emit = [&](bool flush) {
            while (true) {
                if (!inThink && !thinkDone) {
                    size_t at = pending.find(startTag);
                    if (at != std::string::npos) {
                        if (at > 0) {
                            std::string c = pending.substr(0, at);
                            answer += c;
                            if (delta) delta(MVNS(c), nil);
                        }
                        pending.erase(0, at + startTag.size());
                        inThink = true;
                        continue;
                    }
                    size_t hold = flush ? 0 : MIN(pending.size(), startTag.size() - 1);
                    size_t give = MVCompleteUTF8Length(pending.substr(0, pending.size() - hold));
                    if (give) {
                        std::string c = pending.substr(0, give);
                        answer += c;
                        if (delta) delta(MVNS(c), nil);
                        pending.erase(0, give);
                    }
                    return;
                }
                if (inThink) {
                    size_t at = std::string::npos, len = 0;
                    for (auto & e : endTags) {
                        size_t f = pending.find(e);
                        if (f != std::string::npos && f < at) { at = f; len = e.size(); }
                    }
                    if (at != std::string::npos) {
                        if (at > 0 && delta) delta(nil, MVNS(pending.substr(0, at)));
                        pending.erase(0, at + len);
                        inThink = false;
                        thinkDone = true;
                        continue;
                    }
                    size_t hold = flush ? 0 : MIN(pending.size(), maxEnd - 1);
                    size_t give = MVCompleteUTF8Length(pending.substr(0, pending.size() - hold));
                    if (give && delta) delta(nil, MVNS(pending.substr(0, give)));
                    pending.erase(0, give);
                    return;
                }
                size_t give = flush ? pending.size() : MVCompleteUTF8Length(pending);
                if (give) {
                    std::string c = pending.substr(0, give);
                    answer += c;
                    if (delta) delta(MVNS(c), nil);
                    pending.erase(0, give);
                }
                return;
            }
        };

        while ((NSInteger) nGen < maxTokens) {
            if (self->_cancel.load()) break;
            llama_token tok = llama_sampler_sample(smpl, self->_ctx, -1);
            if (llama_vocab_is_eog(self->_vocab, tok)) break;
            llama_sampler_accept(smpl, tok);

            char buf[256];
            int32_t n = llama_token_to_piece(self->_vocab, tok, buf, sizeof buf, 0, true);
            if (n > 0) { pending.append(buf, n); emit(false); }

            if (self->_cached.size() + 1 >= nctx) { err = @"ran out of room in the context window"; break; }
            llama_batch b = llama_batch_get_one(&tok, 1);
            if (llama_decode(self->_ctx, b) != 0) { err = @"the model stopped part way through"; break; }
            self->_cached.push_back(tok);
            nGen++;
        }
        emit(true);
        llama_sampler_free(smpl);

        const double genSecs = -[t1 timeIntervalSinceNow];
        NSMutableDictionary *timings = [NSMutableDictionary dictionary];
        timings[@"prompt_n"]    = @(nPrompt);
        timings[@"predicted_n"] = @(nGen);
        if (promptSecs > 0 && nPrompt) timings[@"prompt_per_second"]    = @(nPrompt / promptSecs);
        if (genSecs > 0 && nGen)       timings[@"predicted_per_second"] = @(nGen / genSecs);
        timings[@"context_used"] = @(self->_cached.size());
        timings[@"context_size"] = @(nctx);

        if (done) done(MVNS(answer), err, timings);
    });
}
@end

#pragma mark - MVGeneration

// A thin handle so the rest of the app can hold "the reply in progress" and
// cancel it, exactly as it did when this was an HTTP request.
@implementation MVGeneration {
    NSMutableString *_text;
}

+ (instancetype)runWithMessages:(NSArray *)messages
                      maxTokens:(NSInteger)maxTokens
                    temperature:(double)temperature
                       thinking:(BOOL)thinking
                        onDelta:(MVDeltaBlock)onDelta
                         onDone:(MVDoneBlock)onDone {
    MVGeneration *g = [MVGeneration new];
    g->_text = [NSMutableString string];
    [[MVEngine shared] generate:messages
                      maxTokens:maxTokens
                    temperature:temperature
                       thinking:thinking
                        onDelta:^(NSString *c, NSString *r) {
                            if (c.length) [g->_text appendString:c];
                            if (onDelta) onDelta(c, r);
                        }
                         onDone:onDone];
    return g;
}

- (NSString *)text { return [_text copy]; }
- (void)cancel { [[MVEngine shared] cancel]; }
@end
