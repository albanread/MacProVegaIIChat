# Recording a demo

`../demo.sh` drives the app through nine beats at a steady pace so a recording is
repeatable. This is the script that goes with it: what is on screen at each beat, roughly
how long it lasts, and something you could say over it.

```bash
./demo.sh              # normal pace
./demo.sh --slow       # longer pauses, easier to narrate over
./demo.sh --cold       # include pressing Start and the model loading
./demo.sh --captions   # put a caption line in the transcript before each beat
```

It stages the app, loads the model **before** the countdown so there is no dead air, then
prints `Start recording now` and counts down from five. Each beat is announced in the
terminal with its number and expected length, so you always know where you are.

## Before you press record

- **Record the window, not the screen.** On a 5K display a 980×720 window becomes a
  postage stamp in a 1080p export. In QuickTime, ⌘⇧5 → *Record Selected Portion* and drag
  around the window, or Screen Recording → click the window itself.
- **Put the terminal somewhere you can see it but the camera cannot.** The beat numbers
  are your cue sheet.
- **Tidy the desktop behind the window**, and turn off notifications. Nothing is worse
  than a Slack banner across the answer.
- **Do one silent take first.** Watch it back before recording narration; the pacing is
  easier to judge than to predict.
- If a take goes wrong, just run `./demo.sh` again — it resets the app to the same state
  every time.

## The beats

Times are how long the beat takes on a Vega II with the 30B-A3B loaded. Everything in the
right-hand column is a suggestion, not a script to read word for word.

| # | On screen | ≈ | What to say |
|---|---|---|---|
| 1 | A question is typed and answered. Grey italic thinking appears, then collapses to *thought for 4 s* | 25 s | "It thinks first, and then tidies the thinking away. Nothing here is going over the internet — the whole model is on the graphics card in this machine." |
| 2 | A document appears in the bar under the toolbar, with its word count | 6 s | "You can drag any document onto the window — text, Markdown, PDF, Word, RTF." |
| 3 | **Summarise it** — a bold headline sentence, then bullets | 15 s | "It has read the whole thing. This one fits in memory, so follow-up questions are instant; a long one gets read in passes and it tells you how many." |
| 4 | **Proofread it** — one line per mistake, `wrong → right` with context | 12 s | "Four real mistakes in that memo, and it found them without rewriting the document or commenting on the style." |
| 5 | A follow-up question, answered from the document | 15 s | "It still has the document in mind, so you can just ask." |
| 6 | The settings panel | 12 s | "Memory is in pages of text rather than tokens. Reply length in pages. Nothing in here needs you to know what a token is." |
| 7 | A second window opens and writes a memo into itself | 25 s | "Now the other direction — ask it to write something. It takes the facts from the document that is open without copying it." |
| 8 | The draft is rewritten, shorter | 15 s | "Changes are asked for in plain English. Make it shorter. Warmer. Drop the greeting." |
| 9 | Put Away — the status line reads *the card is free again* | 6 s | "And it hands the card back when you are done with it." |

Total is a little over two minutes of screen time.

## Two lines worth landing

If you say nothing else, say these.

> This is a Mac Pro from 2019. The card in it has 32 GB of memory, and until recently that
> was no use at all for running AI models.

and, at the end, over the status line:

> That figure is what this card actually managed, measured as it went. It is not a
> published benchmark from somebody else's machine.

## What to cut

- **The model loading.** `--cold` puts it in shot if you want it, but it is 25 seconds of
  a progress bar. Either narrate over it or leave it out.
- **The gaps between beats** if the silent take feels slow — the pauses are sized for
  reading aloud, not for reading.
- **The first two seconds of any answer**, if you want a tighter cut. The interesting part
  is the answer arriving, not the pause before it.

## If it goes wrong

The demo talks to the app over Apple Events. If a command fails:

- `the model is not loaded yet` — the countdown started before loading finished. Run it
  again; `demo.sh` waits for readiness before the countdown, so this should not happen.
- Nothing happens at all — macOS is asking to allow automation. Approve it once, then
  re-run.
- The window is behind something — `demo.sh` fronts it with System Events, which needs
  Accessibility permission the first time.
