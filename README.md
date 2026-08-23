# MacVegaII Chat

**A local AI for the Mac Pro (2019) with a Radeon Pro Vega II — a card that could not run
language models at all until the fixes this is built on.**

That machine has 32 GB of graphics memory sitting in it, and it was useless for this work:
llama.cpp picked the wrong GPU on a two-card Mac Pro, and its Metal kernels assumed 32-wide
SIMD groups where AMD's are 64-wide, so the reductions folded over the wrong lane count and
produced fluent nonsense. [IntelMacLlamaCpp](https://github.com/albanread/IntelMacLlamaCpp)
fixes both. This is the app that sits on top: download a model, press Start, and talk to it
— or hand it a document to read, or ask it to write one. No account, no sign-in, no cloud.
Nothing you type and no document you open ever leaves the machine.

On that card a Qwen3 30B-A3B answers at about 52 tokens a second. It is not a compromise.

![minimum macOS 13.0](https://img.shields.io/badge/macOS-13.0%2B-lightgrey) ![x86_64](https://img.shields.io/badge/arch-x86__64-blue) ![licence MIT](https://img.shields.io/badge/licence-MIT-blue)

### Scope, stated plainly

Built and tested on **one machine**: a Mac Pro 7,1 with a Radeon Pro Vega II (32 GB),
macOS 26.3. That is the whole of the evidence. It is not a claim about AMD GPUs in general,
or even about other Vega IIs — nobody sends us hardware, so we cannot say. The fixes are
about wave64 SIMD width rather than one specific chip, so there is reason to think they
generalise; reason-to-think is not testing, and we are not going to dress it up as support.
If you run it on something else, please say what happened.

### Where it is up to

Version 0.2.0 links llama.cpp into the app rather than spawning `llama-server`. Chat,
document reading, drafting, the settings panel and the whole scripting interface have been
exercised on the machine above. Still unverified at the time of writing: the launch-time
Metal warm-up, multi-pass reading of a very long document, and the download path for the
four models nobody has timed yet. The next rebuild is waiting on verification of the wave64
backend work upstream.

## Why this exists

Stock llama.cpp does two things wrong on a Mac Pro:

1. **It picks the wrong GPU.** `MTLCreateSystemDefaultDevice()` returns the GPU driving
   your display. On a Mac Pro that is often the small card — and if it only reports
   Metal 2, llama.cpp's Metal backend is disabled entirely and silently.
2. **Its kernels assume 32-wide SIMD groups.** AMD GCN cards are 64-wide, so the
   reductions fold over the wrong lane count and you get fluent nonsense.

This app links a [fixed llama.cpp](https://github.com/albanread/IntelMacLlamaCpp) and
picks the Metal device itself, so none of that is the user's problem.

## What it does

**Talk to it.** An ordinary chat window. Multi-line input, Return to send, Shift-Return
for a new line. The conversation is trimmed when it outgrows the model's memory, and it
says so when it does.

**Give it a document.** Drop a file on the window, press ⌘O, or drop it on the app icon.
It reads plain text, Markdown, source code, PDF, RTF, Word (.doc/.docx), ODT and HTML.
Then pick a job from the Review menu:

| | |
|---|---|
| Summarise it | one sentence of headline, then the bullets |
| Pull out the key points | in the order they appear, figures and dates intact |
| Review and critique it | what works, what is unclear, what is missing, what to cut |
| Proofread it | one line per mistake, `wrong → right` with context |
| Extract the action items | owner — action — when |
| Explain it simply | plain English, jargon defined |

Or simply ask it questions about the document.

A document that fits in the model's memory is put into the conversation once, so
follow-up questions are ordinary turns and stay fast. **A document that does not fit is
read in passes** — a determinate progress bar shows how many, and a final pass puts the
notes together. It says how long it will be, rather than failing or quietly truncating.

**Have it write one.** ⌘D opens a short panel: what kind of document, what it is for,
tone, length, and whether to draw on the document you have open. The result opens in its
own window where you can edit it, ask for changes in plain English ("make it shorter",
"warmer tone", "add a closing line"), and then Copy, Save as Markdown / plain text / RTF
/ Word, or Print — which is also how you get a PDF on a Mac.

**Settings that explain themselves.** Memory is measured in pages of text rather than
tokens; reply length in pages rather than a token count; sampling temperature is
Precise / Balanced / Inventive. There are standing instructions that go ahead of every
conversation, a switch for whether it thinks before answering, and text size.

**It can be driven by a script.** See [Scripting](SCRIPTING.md).

## Build

You need llama.cpp built as static libraries first — the app links them in, so there is
no separate engine binary to ship:

```bash
cd /Volumes/S/llama.cpp
cmake -B build-rel -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DBUILD_SHARED_LIBS=OFF \
      -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DLLAMA_CURL=OFF
cmake --build build-rel -j --target llama-common
```

`BUILD_SHARED_LIBS=OFF` and `GGML_METAL_EMBED_LIBRARY=ON` both matter: the app has to be
one relocatable binary with the Metal shaders inside it.

Then:

```bash
./build.sh      # compiles the app and links llama.cpp into it
./makedmg.sh    # produces MacVegaIIChat-<version>.dmg
```

`build.sh` looks for llama.cpp at `/Volumes/S/llama.cpp`; set `LLAMA_CPP` to point
somewhere else.

See [SIGNING.md](SIGNING.md) for notarisation. Unsigned, macOS **SIGKILLs** a downloaded
copy — ad-hoc signing does not help, only Developer ID + notarisation does.

## Design notes

- **llama.cpp is linked in, not spawned.** It used to run `llama-server` as a child
  process and speak OpenAI-style HTTP to it on the loopback. Linking the library in
  removed every problem that came with owning a second process — no ports, no `/health`
  poll, and no 18 GB engine left resident in VRAM when the app is killed. It also made
  the tokeniser available in-process, so the context meter and the document splitter
  work in real tokens rather than a chars-÷-3 guess. Generation measured slightly faster
  in-process than over HTTP (39.8 vs 32.8 tok/s on the 30B-A3B), and a short reply that
  took 40 s round-trip takes 6 s.
- **The trade accepted.** A fault in the GPU backend now takes the window down with it,
  where before the app survived and offered to restart the engine. That is the real cost
  of binding it in, and it is worth knowing about while the wave64 kernels are still
  being worked on.
- **GPU choice.** `BestMetalDevice()` walks `MTLCopyAllDevices()` and prefers a Metal 3
  device with the most VRAM, then names it in `GGML_METAL_DEVICE` — an environment
  variable added by the fork, read when the Metal device is created.
- **No mmap.** `LLAMA_LOAD_MODE_NONE`, so weights are loaded into VRAM rather than
  mapped. With mmap the GPU reads weights across PCIe and throughput collapses by
  roughly 16×.
- **Prompt cache.** The tokens currently in the KV cache are kept, and a new prompt only
  re-decodes from the first token that differs. That is why a follow-up question answers
  in about a second rather than re-reading the whole conversation.
- **The model's own chat template.** Every GGUF carries the template it was trained
  with, and the app uses it — `common_chat_templates_init(model, "")`, rendered through
  Jinja, with the BOS/EOS strings taken from the vocab. It is never told what format to
  use. That is also where the reasoning markers come from: `<think>` for Qwen3, `[THINK]`
  for Magistral, `<|channel|>analysis<|message|>` for gpt-oss. Nothing about a model
  family is hardcoded here, which is what lets "use a model file I already have" work at
  all. Two consequences the app surfaces rather than hides: a file with no template of
  its own falls back to ChatML and it says so, and a model whose template has no
  reasoning mode is reported as answering straight away instead of silently ignoring the
  thinking setting. The template is also rendered once at load, so one that only breaks
  when used breaks at Start rather than on the user's first message.
- **Reasoning models.** Qwen3 thinks before it answers. The thinking is shown as it
  arrives — otherwise the window sits blank and looks hung — and then folded away to
  "thought for 12 s" once the answer starts. If a model spends its whole reply budget
  thinking and never reaches an answer, the app asks again with thinking turned off
  rather than showing you nothing. Reading and drafting never think: they are mechanical
  jobs, and thinking about them mostly costs time.
- **One copy at a time.** Two instances would mean two models resident, so a second
  launch hands over to the first.

## Supported hardware

The scope is [as stated at the top](#scope-stated-plainly): one Mac Pro 7,1 with a Radeon
Pro Vega II. A different Vega II, a W5700X, a W6800X, a different macOS — all untested.

One thing is worth knowing whatever card you have.

Cards that report only **Metal 2 cannot work at all**. The GPU backend depends on
simdgroup reduction, which these cards expose via Metal 3; without it llama.cpp disables
almost every kernel. The Radeon Pro 580X fitted to many Mac Pros is such a card, so on a
machine with both, the app must pick the Vega II — which is exactly what it does. If the
best available GPU is not Metal 3 capable, the app says so on launch rather than
producing wrong output.

## Models

Seven are offered, with a tick beside the ones already on this Mac. Speeds are what was
actually measured on a Radeon Pro Vega II; where nobody has timed one the app says so
rather than inventing a figure.

| Model | Download | Wants about | Measured |
|---|---|---|---|
| Llama 3.2 3B `Q5_K_M` | 2.3 GB | 4 GB | 54.4 tok/s |
| Qwen3 4B `Q4_K_M` | 2.5 GB | 4 GB | — |
| Qwen3 8B `Q4_K_M` | 5.0 GB | 7 GB | 46.9 tok/s |
| Qwen3 14B `Q4_K_M` | 9.0 GB | 12 GB | — |
| Gemma 4 26B-A4B `QAT UD-Q4_K_XL` | 14.2 GB | 17 GB | — |
| Qwen3 30B-A3B `Q4_K_M` | 18.6 GB | 22 GB | 51.9 tok/s |
| Qwen3 32B `Q4_K_M` | 19.8 GB | 24 GB | — |

**The useful thing those numbers say:** on this card, the biggest download is also very
nearly the fastest. Qwen3 30B-A3B runs at 51.9 tok/s — within a whisker of a 3B model —
because only about 3B of its parameters are active per token. A dense 12B managed 20.6
tok/s on the same card — less than half the speed for a third of the size. So the advice on a 32 GB card is not "pick something small to keep it
quick"; it is "take the mixture-of-experts model, it is both the best and the fastest".
The app orders the list by size but opens on the quickest model you already have that
fits.

A Gemma 3 12B was measured here too, and is deliberately not offered: it invented things
in testing on this machine often enough to be untrustworthy for reading documents, which
is most of what this app is for. Its speed figure is quoted above only because it is a
useful measurement of the card.

Gemma 4's 26B-A4B is the other mixture-of-experts option, and it is offered **only** as
`unsloth/gemma-4-26B-A4B-it-qat-UD-Q4_K_XL` — the quantisation-aware build. That is
deliberate. The plain post-training-quantised build of the same model has noticeably
higher perplexity and was found to invent things, so it is not in the list and should not
be substituted in. QAT is trained with the four-bit rounding in the loop rather than
having it applied afterwards, and on this model that is the difference between usable and
not. It is also the smaller download of the two, at 14.2 GB against 16.9.

Because the app times every reply anyway, your own measured rate replaces the table for
any model you have actually used — which is the only figure that means anything on a card
other than a Vega II.

"Use a model file I already have…" at the bottom of the same menu takes any GGUF —
useful if you have a shelf of them already and no wish to download another. The chat
template, the special tokens and the reasoning markers all come out of the file, so
anything llama.cpp can load should work, and new model families need no change here.

## Limitations

- x86_64 only, by design.
- No conversation persistence and no multi-chat. The transcript can be saved as
  Markdown; the conversation itself is not restored on reopening.
- Scanned PDFs with no text layer cannot be read — there is no OCR.

## Licence

MIT. Links llama.cpp, also MIT.
