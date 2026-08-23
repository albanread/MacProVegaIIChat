# Driving the app from a script

The app is scriptable, mostly so it can be tested without anyone sitting in front of it.
Everything the window does, a script can do — including taking a picture of the window,
which is how you check that a change looks right from a terminal.

Target it by path, so you do not have to install it first:

```applescript
tell application "/Volumes/S/MacVegaChat/MacVegaIIChat.app"
    …
end tell
```

The first time a script talks to it, macOS asks you to allow automation. That is a
one-off, per calling app.

## Waiting

Anything that involves the model takes longer than the two minutes AppleScript allows by
default, so wrap it:

```applescript
with timeout of 900 seconds
    …
end timeout
```

`start engine` returns as soon as loading begins. `wait until ready` blocks until the
model is loaded *and* idle, and returns `false` if it gives up:

```applescript
tell application "…/MacVegaIIChat.app"
    start engine
    if not (wait until ready timeout 600) then error "model never came up"
end tell
```

The commands that produce text — `ask`, `review document`, `write document`,
`revise draft` — suspend the event and return the finished answer, so there is nothing
to poll.

## Commands

| Command | Result |
|---|---|
| `start engine` | `true` if loading started |
| `stop engine` | — |
| `wait until ready [timeout n]` | `true`, or `false` on timeout |
| `select model "8B"` | `true` if a model matched the name |
| `new chat` | — |
| `ask "…"` | the answer |
| `attach document "/path"` | a line describing what was read |
| `detach document` | — |
| `review document "summarise" [document "/path"]` | the review |
| `write document "brief" [kind …] [tone …] [length …] [using document true]` | the draft |
| `revise draft "make it shorter"` | the revised draft |
| `open panel "settings"` / `close panel` | — |
| `screenshot "/path.png" [window "main"\|"draft"\|"panel"]` | the path written |

`review document` takes `summarise`, `key points`, `critique`, `proofread`, `actions` or
`explain`. Anything else it does not recognise is treated as a question about the
document.

## Properties

Read-only unless noted: `engine running`, `busy`, `status`, `transcript`, `last answer`,
`model name`, `gpu name`, `attached document`, and `draft text` (read/write — setting it
replaces the frontmost draft, or opens a new one).

## Screenshots

`screenshot` renders the app's own window into a PNG. It captures the view hierarchy
rather than the screen, so it needs no screen-recording permission and works with the
window behind others — but it does not include the title bar.

```bash
osascript -e 'tell application "…/MacVegaIIChat.app" to screenshot "/tmp/shot.png"'
```

## A worked example

```applescript
with timeout of 1800 seconds
    tell application "/Volumes/S/MacVegaChat/MacVegaIIChat.app"
        start engine
        if not (wait until ready timeout 600) then error "no model"

        new chat
        attach document (POSIX path of (choose file))
        set findings to review document "proofread"

        write document "a covering note explaining the corrections" ¬
            kind "Email" tone "Friendly" length "short" using document true
        revise draft "drop the greeting and start with the point"

        screenshot "/tmp/draft.png" window "draft"
        return findings
    end tell
end timeout
```

`test.sh` in this directory runs a version of that end to end and leaves its screenshots
in `build/shots`.
