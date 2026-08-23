#!/bin/zsh
# End-to-end check: loads the model, reads a document, drafts one, and leaves
# screenshots in build/shots. Takes a few minutes and needs the GPU to itself.
set -e
cd "$(dirname "$0")"
APP="$PWD/MacVegaIIChat.app"
SHOTS="$PWD/build/shots"
DOC="$PWD/build/test-memo.md"
[ -d "$APP" ] || { echo "build the app first (./build.sh)"; exit 1; }
mkdir -p "$SHOTS" "$(dirname "$DOC")"

cat > "$DOC" <<'TXT'
# Workshop move

We are moving the workshop from room 2B to the annexe over the weekend of the
14th. Clear your personal tooling out of 2B by Friday the 12th at 5pm.

Alan is coordinating the lathe move. Priya will handle the electrical sign-off
on the monday morning. There will be no access to either room on the saturday.

If your fob does not work on the 17th, come and see us and dont just prop the
door open, its a fire door.
TXT

say_step() { print -P "%F{cyan}==>%f $1"; }

pkill -f "MacVegaIIChat.app/Contents/MacOS/MacVegaIIChat" 2>/dev/null || true
sleep 1
open "$APP"
sleep 3

say_step "loading the model"
osascript <<AS
with timeout of 1800 seconds
  tell application "$APP"
    start engine
    if not (wait until ready timeout 900) then error "the model never came up"
    screenshot "$SHOTS/1-ready.png"
  end tell
end timeout
AS

say_step "reading a document"
osascript <<AS
with timeout of 1800 seconds
  tell application "$APP"
    new chat
    attach document "$DOC"
    set r to review document "proofread"
    screenshot "$SHOTS/2-review.png"
    if r is "" then error "the review came back empty"
    log r
  end tell
end timeout
AS

say_step "writing a document"
osascript <<AS
with timeout of 1800 seconds
  tell application "$APP"
    write document "a short note telling the workshop users the move is finished" ¬
        kind "Memo" tone "Friendly" length "short" using document true
    revise draft "make it two sentences shorter"
    screenshot "$SHOTS/3-draft.png" window "draft"
    if draft text is "" then error "the draft came back empty"
  end tell
end timeout
AS

say_step "settings panel"
osascript <<AS
tell application "$APP"
  open panel "settings"
  delay 1
  screenshot "$SHOTS/4-settings.png" window "panel"
  close panel
end tell
AS

say_step "putting the model away"
osascript -e "tell application \"$APP\" to stop engine"
print -P "%F{green}==>%f all good — screenshots in $SHOTS"
