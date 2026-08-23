#!/bin/zsh
set -e
setopt NULL_GLOB 2>/dev/null || true
cd "$(dirname "$0")"
APP="MacVegaIIChat.app"
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="MacVegaIIChat-$VER.dmg"
STAGE=build/dmg

[ -d "$APP" ] || { echo "build the app first (./build.sh)"; exit 1; }
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
MacVegaII Chat — a local AI for the Mac Pro (2019) + Radeon Pro Vega II
======================================================================

Drag MacVegaIIChat.app to Applications, then open it.

Everything happens on your Mac. No account, no sign-in, no telemetry. Nothing
you type, and no document you open, ever leaves the machine.

WHAT IT NEEDS
  • macOS 13 (Ventura) or later
  • A Mac Pro (2019) with a Radeon Pro Vega II. To be exact: this has been built
    and tested on ONE machine of that description. Anything else — a different
    Vega II, a W5700X, a W6800X — is genuinely untested rather than "supported".
    It may well work; we simply do not know, and would like to hear.
    Cards that report only Metal 2, such as the Radeon Pro 580X fitted to many
    Mac Pros, CANNOT work: the maths needs Metal 3. The app checks and tells you
    rather than producing wrong answers.
    The app picks the best GPU automatically. On a Mac Pro the GPU driving your
    display is often NOT the fastest one, and stock llama.cpp gets this wrong.
  • Room for a model — from 2.5 GB for the smallest to about 20 GB.

FIRST RUN
  1. Choose a model from the menu at the top. Qwen3 8B is the safe first choice.
     Qwen3 30B-A3B is quicker AND better, but wants a 32 GB card.
  2. Press Download. This fetches it from Hugging Face — several GB, once.
     Models already on this Mac have a tick beside them.
  3. Press Start, wait for "Ready", then type.

WHAT YOU CAN DO WITH IT
  • Just talk to it. Return sends, Shift-Return starts a new line.
  • Drop a document on the window — text, Markdown, PDF, Word, RTF, HTML — and
    use the Review menu that appears: summarise, proofread, critique, pull out
    the action items, explain it simply. Or just ask questions about it.
    Long documents are read in several passes; it tells you how many.
  • Press Cmd-D and it will write a document for you — letter, email, memo,
    report and so on. The draft opens in its own window where you can edit it,
    ask for changes in plain English, and save or print it.
  • Settings (Cmd-,) are written in plain language: how much it keeps in mind,
    how long answers can be, how careful or inventive it should be.

IF macOS REFUSES TO OPEN IT
  If you downloaded this with a web browser, macOS quarantines it. Either
  right-click the app and choose Open, or run:

      xattr -dr com.apple.quarantine /Applications/MacVegaIIChat.app

NOTES
  • Start takes a minute the first time — the model is being loaded onto the
    graphics card. After that it stays ready until you press Put Away or quit.
  • Qwen3 thinks before answering. You will see the thinking in grey while it
    works, and it is tidied away once the answer arrives. There is a switch in
    Settings if you would rather keep it, or skip it.
  • Built on llama.cpp (MIT), with fixes for AMD wave64 GPUs that upstream does
    not yet have: https://github.com/albanread/IntelMacLlamaCpp
TXT

hdiutil create -volname "MacVegaII Chat" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "==> $DMG  ($(du -h "$DMG" | cut -f1))"
hdiutil verify "$DMG" >/dev/null && echo "==> image verifies"
