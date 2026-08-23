#!/bin/zsh
# A repeatable demo of the app, paced for screen recording.
#
#   ./demo.sh                  normal pace, model already loaded
#   ./demo.sh --slow           longer pauses, for narrating over
#   ./demo.sh --fast           tighter, for a short clip
#   ./demo.sh --cold           include pressing Start and the model loading
#   ./demo.sh --captions       write a caption into the transcript before each beat
#
# Every beat is announced in the terminal with its number and rough length, so
# you always know where you are. Nothing here depends on the model saying any
# particular thing, so takes are comparable.
set -e
cd "$(dirname "$0")"
APP="$PWD/MacVegaIIChat.app"
DOC="$PWD/build/demo-memo.md"
PACE=1.0
COLD=0
CAPTIONS=0

for arg in "$@"; do
  case "$arg" in
    --slow)     PACE=1.6 ;;
    --fast)     PACE=0.6 ;;
    --cold)     COLD=1 ;;
    --captions) CAPTIONS=1 ;;
    *) echo "unknown option: $arg"; exit 1 ;;
  esac
done
[ -d "$APP" ] || { echo "build the app first (./build.sh)"; exit 1; }
mkdir -p "$(dirname "$DOC")"

# The document the demo works from. Short enough to fit on screen, and it has
# four real mistakes in it so the proofreader has something to find.
cat > "$DOC" <<'TXT'
# Workshop move — draft memo

To: everyone on the second floor
From: Facilities

We are moving the workshop from room 2B to the annexe over the weekend of the
14th. This has been discussed for a while and is now confirmed.

Reasons: 2B has no extraction, the benches are too small for the new lathe, and
the annexe has three-phase power already run in.

What you need to do. Clear your personal tooling out of 2B by Friday the 12th at
5pm. Anything left will be boxed and put in the store, and we make no promise
about how carefully. Label your boxes with your name and the department.

Alan is coordinating the lathe move with the contractor. Priya will handle the
electrical sign-off on the monday morning before anyone uses the benches. There
will be no access to either room on the saturday.

The annexe key fobs will be reprogrammed on the 16th, so if your fob does not
work on the 17th, that is why — come and see us and dont just prop the door
open, its a fire door.

We know this is disruptive and we appreciate everyones patience with it.
TXT

BEAT=0
TOTAL=9
osa() { osascript -e "with timeout of 1800 seconds" -e "tell application \"$APP\"" "$@" -e "end tell" -e "end timeout"; }
beat() {                       # beat <title> <expected seconds>
  BEAT=$((BEAT+1))
  print -P "%F{cyan}[$BEAT/$TOTAL]%f $1  %F{242}(about $2s)%f"
  [ $CAPTIONS -eq 1 ] && osa -e "note \"— $1 —\"" >/dev/null
  return 0
}
hold() { sleep $(python3 -c "print($1 * $PACE)"); }

# ---------------------------------------------------------------- staging ---
print -P "%F{242}staging…%f"
pkill -f "MacVegaIIChat.app/Contents/MacOS/MacVegaIIChat" 2>/dev/null || true
sleep 1
open "$APP"
sleep 3
osa -e 'resize width 980 height 720' >/dev/null
osascript -e 'tell application "System Events" to set frontmost of process "MacVegaIIChat" to true' 2>/dev/null || true

if [ $COLD -eq 0 ]; then
  print -P "%F{242}loading the model before we start, so there is no dead air…%f"
  osa -e 'start engine' -e 'wait until ready timeout 900' >/dev/null
  osa -e 'new chat' >/dev/null
  TOTAL=9
else
  TOTAL=10
fi

# -------------------------------------------------------------- countdown ---
print -P "\n%F{green}Start recording now.%f  Beginning in:"
for i in 5 4 3 2 1; do print -n "  $i"; sleep 1; done
print "\n"

# ------------------------------------------------------------------ beats ---
if [ $COLD -eq 1 ]; then
  beat "Pressing Start — the model loads onto the graphics card" 30
  osa -e 'start engine' >/dev/null
  osa -e 'wait until ready timeout 900' >/dev/null
  hold 3
fi

beat "An ordinary question — watch the thinking fold away when the answer starts" 25
osa -e 'ask "What is a metal lathe, and what would I use one for? Two short paragraphs."' >/dev/null
hold 5

beat "Handing it a document" 6
osa -e "attach document \"$DOC\"" >/dev/null
hold 5

beat "Summarise it" 15
osa -e 'review document "summarise"' >/dev/null
hold 6

beat "Proofread it — four real mistakes are in there" 12
osa -e 'review document "proofread"' >/dev/null
hold 6

beat "Asking about the document, which it still has in mind" 15
osa -e 'ask "Who is doing the electrical sign-off, and when?"' >/dev/null
hold 6

beat "The settings — pages of text, not tokens" 12
osa -e 'open panel "settings"' >/dev/null
hold 10
osa -e 'close panel' >/dev/null
hold 2

beat "Asking it to write a document" 25
osa -e 'write document "a short follow-up note telling the same people the move is finished, the annexe is open, and where to report problems" kind "Memo" tone "Friendly" length "short" using document true' >/dev/null
hold 6

beat "Changing it, in plain English" 15
osa -e 'revise draft "drop the greeting and make it two sentences shorter"' >/dev/null
hold 6

beat "Putting the model away — the card is free again" 6
osa -e 'stop engine' >/dev/null
hold 4

print -P "\n%F{green}Done.%f  Stop recording."
print -P "%F{242}$(osa -e 'get status')%f"
