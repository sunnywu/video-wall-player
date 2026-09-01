# sixplayer
Open **6 videos at once**, fill the whole main screen with a **3×2 grid**, and
**nudge each one individually with one key**. Every video **starts muted**; one
key unmutes any of them. Powered by the VLC that already ships with
`/Applications/VLC.app` (`libVLC` 3.0.23) — no extra install.

## Run it

```sh
~/vlc6/run.sh
```

With **no arguments** this opens the **drag‑and‑drop picker**: a window with a
drop area, a running list and count of accepted videos, and a **Play** button
that stays disabled until exactly **six** are selected. Drop video files, then
press **Play** (or **Return**) and the picker closes and the six‑cell 3×2 wall
starts — the same wall as before, muted by default.

A centered cheat sheet overlays for 9 seconds then hides. Press `?` to show or
hide it; Esc still works too.
The window fills the main display, joins all spaces, and stays on top until **q** / **Cmd‑Q**.
Click the screen once after it appears so it has keyboard focus.

## Build In Xcode

Open `sixplayer.xcodeproj` in Xcode, select the `sixplayer` scheme, then build or
run it. The app target links against the VLC libraries inside
`/Applications/VLC.app`, so keep VLC installed there for developer builds.

The command-line launcher also builds through the Xcode project:

```sh
~/vlc6/run.sh
```

## Create A Shareable App

To create a copyable app for other people:

```sh
make package
```

This builds `dist/Video Wall Player.app`, embeds the VLC runtime files it needs,
signs the app locally, and creates:

* `dist/Video Wall Player.zip` — unzip, then drag the app into Applications.
* `dist/Video Wall Player.dmg` — open, then drag the app to Applications.

The packaged app does not require VLC to be installed separately. It is locally
signed, not Apple-notarized, so macOS may require right-click → Open on first
launch when sharing it outside this Mac.

## Key map — each video owns one letter

| Cell | Key | Forward (+1 min) | Backward (-1 min) | Fast Jump (+/-5 min) | Mute On/Off |
|:---:|:---:|:---:|:---:|:---:|:---:|
| 1 | **A** | `A` | `Shift+A` | `Control+A` / `Shift+Control+A` | `Option+A` |
| 2 | **S** | `S` | `Shift+S` | `Control+S` / `Shift+Control+S` | `Option+S` |
| 3 | **D** | `D` | `Shift+D` | `Control+D` / `Shift+Control+D` | `Option+D` |
| 4 | **Z** | `Z` | `Shift+Z` | `Control+Z` / `Shift+Control+Z` | `Option+Z` |
| 5 | **X** | `X` | `Shift+X` | `Control+X` / `Shift+Control+X` | `Option+X` |
| 6 | **C** | `C` | `Shift+C` | `Control+C` / `Shift+Control+C` | `Option+C` |

* A plain letter = **forward** 1 minute.
* `Shift+` letter = **backward** 1 minute.
* `Control+` letter = **forward** 5 minutes.
* `Shift+Control+` letter = **backward** 5 minutes.
* `Option+` letter = **toggle that video's sound** (muted ⇄ playing audio).
* `q` or **Cmd‑Q** quit · `?` or **Esc** show/hide cheat sheet.
* Change the normal skip with `SKIP=30 ~/vlc6/run.sh`.
* Change the Control skip with `CONTROL_SKIP=600 ~/vlc6/run.sh`.

Cells are numbered `1→6`, left‑to‑right, top‑to‑bottom:
```
+------+------+--------+
|  1   |  2   |  3     |     a    s    d
|  A   |  S   |  D     |
+------+------+--------+
|  4   |  5   |  6     |     z    x    c
|  Z   |  X   |  C     |
+------+------+--------+
```

## Choosing the 6 videos
There are two ways videos get into the grid.

**1 — The drag‑and‑drop picker (the default interactive launch).**
Drag video files into the window, one at a time or a whole batch. The picker:
* accepts **only video files** — folders and non‑video files are skipped
  automatically, and a short status line reports what was skipped on the last
  drop (a dropped *folder* is not a video even if its name ends in `.mp4`);
* **de‑duplicates by path** — dropping the same file again does nothing;
* **caps at six** — dropping more than six keeps the first six and tells you how
  many extras were skipped;
* shows the count as *"_N_ of 6 videos selected"* and **enables Play** the instant
  six are present. Drop more, or click **Remove selected** / **Clear**, and the
  button goes back to disabled.

Press **Play** (or **Return**) and the picker closes and the six‑cell wall
starts — muted by default, per‑video keys, `?`/Esc cheat sheet (see the key
map below).

**3 — Swap a video mid‑play (drop onto a cell).**
Once the wall is playing you can **drag a new video from the Finder onto any one
of the six cells** to replace just that cell: drop a video onto cell **A**, for
example, and cell A stops, the new file opens, and **plays in place** while the
other five cells keep running untouched. The replacement starts **muted**, like
every cell. Only the first accepted video file in the drop is used; folders and
non‑video files are ignored (same rules as the picker).

**2 — The command line (bypasses the picker).**
Pass up to six video paths and they play **directly**, with no picker:

```sh
~/vlc6/run.sh /path/a.mp4 /path/b.mp4 …     # up to 6, in this order
```

This is the fast path for scripts and the self‑tests. Direct‑playback runs the
app's original `resolvePaths()`: your CLI paths play in the order given, and the
random‑from‑`~/Downloads` default the app always used is **preserved in code** for
non‑interactive callers — the interactive no‑path case now opens the picker
instead of auto‑playing random files.

Recognized video extensions include `mp4`, `m4v`, `mov`, `mkv`, `avi`,
`webm`, `mpg`, `mpeg`, `wmv`, `flv`, `ts`, `mts`, and `m2ts`.

## macOS TCC
On macOS a non‑bundled/ad‑hoc executable can be **denied read access to
`~/Downloads`**. If a cell stays black:
* grant the *launching terminal* **Full Disk Access** (System Settings → Privacy &
  Security → Full Disk Access), then launch again.

## Control self‑tests

```sh
~/vlc6/run.sh selftest         # build the full UI, then auto-exit (SELFTIME s, default 3)
SELFTIME=6 ~/vlc6/run.sh selftest
```
`selftest` uses the six videos copied from `~/Downloads` (or `test/`) and verifies that all
6 players enter the playing state.

### Selection self‑test (headless, no VLC, no window)

```sh
~/vlc6/run.sh seltest         # build, then run the picker's selection/routing checks
```

`seltest` exercises the **testable selection seam** — the `VideoWallSelection`
model plus launch routing and the Play handoff — **without** opening a window or
touching libVLC, as the issue allows for GUI-level testing. It confirms: folders /
non‑videos / duplicate drops are skipped, the selection caps at six (extras
reported), the **Play** button toggles only with exactly six selected, Clear /
Remove work, and that six paths hand off to the real player in **drop order**.
It also checks the **drop‑replace filter seam** (only video files are accepted
onto a cell; folders and non‑videos rejected) and the `replaceCellVideo` guard
clauses (a bad cell / non‑video / empty path is refused). It exits non‑zero if
any check fails:

```
[sixplayer] selection self-test: 42 check(s), 0 failed -> PASS
```

This is the test for "the drop rules are right" — it runs anywhere, even from an
agent/SSH session, since it needs no GUI.

### Drop‑replace self‑test (issue #14, windowed)

```sh
~/vlc6/run.sh droptest        # build the wall, drop a new video onto cell 2, verify it plays
```

`droptest` builds the running six‑cell wall, then drives the **full drop path** —
it hands cell 2 a real Finder‑style file drop (a file URL on the drag pasteboard)
through `CellView performDragOperation:` → `replaceCellVideo` and confirms the
new video **opens and plays** while the other five cells keep playing. It uses a
video from `~/Downloads` as the dropped source, so it needs a GUI session and
VLC available:

```
[sixplayer] drop-replace integration self-test: 4 check(s), 0 failed -> PASS
```

## Render self‑test — prove all 6 cells actually paint (not black)

```sh
~/vlc6/run.sh render        # snapshot all 6 grid cells, confirm none is black/blank
```

This is the test for “only some cells show video.” It waits about 20 s for the videos to
render, **snapshots the full screen** with Apple’s `screencapture`, then measures each
of the 6 cell regions and prints a per‑cell verdict:

```
cell 1 (a) RENDER: maxLum=.. range=.. f2max=.. f2range=.. move=.. -> PASS   (or FAIL (black/blank))
…
RENDERCHECK result: 6/6 cells rendering -> PASS (all 6 non-black)
```

* A cell **FAILS** when its region is flat / near‑zero luminance with no range and no
  motion between two captures — i.e. a blank screen. A real video passes on bright
  pixels, wide luminance range, or frame‑to‑frame motion (so a momentarily‑dark frame
  does not read as blank).
* **Run it from a GUI terminal (Terminal/iTerm).** macOS Screen‑Recording permissions
  are needed to read pixels. If it prints `RENDERCHECK FAIL: no usable screen capture`,
  it could not read the screen — that is **not** a pass: grant the launching terminal
  **Screen Recording** (System Settings → Privacy & Security → Screen Recording). It also
  cannot run from an agent/SSH session (no GUI).
* It exits non‑zero when any cell is blank, so it is script‑friendly.
* It logs a `DIAG` per‑cell snapshot (libVLC state/time/mute) too — useful headlessly,
  where it confirms all 6 are `Playing` and **muted** even when the screen can’t be read.

## How it works
* **App + grid:** one `NSApplication`, six tiled borderless windows arranged as a
  3×2 grid, plus a temporary overlay window for the cheat sheet.
* **Embedding via libVLC:** each cell gets a `libvlc_media_player_t` wired into its
  `NSView` with **`libvlc_media_player_set_nsobject`** (VLC's documented macOS
  embedding primitive). Each VLC player decodes and renders into its own view via
  **VideoToolbox**, so 6 streams stay lightweight — we don't blit frames ourselves.
* **Per‑video control** calls straight into libVLC: seek =
  `libvlc_media_player_get_time`+`…_set_time`; sound =
  `libvlc_audio_set_mute` (start, all 6 muted) / `…_toggle_mute` + `…_set_volume`.
* **Drop‑replace (issue #14):** each `CellView` registers as a Finder drop target.
  Dropping a video calls `replaceCellVideo(cell, path)`, which releases that cell's
  old media/player, builds a fresh media from the dropped file, re‑embeds it into the
  same view, and starts it muted — the replacement opens and plays in the cell.
* **Header‑drift proof:** the only libVLC symbols are declared via `extern` directly in
  the source, so the build is independent of which version of `libvlc.h` is installed.

## Layout
| File | What |
|---|---|
| `run.sh`      | build (if stale) + launch; supports `seltest` / `selftest` / `droptest` / `render` / `SKIP=` / `CONTROL_SKIP=` / path args |
| `sixplayer.m` | the app + `VideoWallSelection` picker model + `SelectionWindowController` UI + the headless `seltest` |
| `sixplayer.xcodeproj` | Xcode project for building the app bundle |

## Verification done
* Compiles clean on Apple Silicon, links `libvlc.dylib`/`libvlccore.dylib` from the
  system VLC via `@rpath`.
* `seltest`: the picker's selection model + routing + Play handoff pass all 42
  headless checks (skips folders / non‑videos / duplicates, caps at six with extras
  reported, Play toggles only with six, Clear/Remove, order‑preserving handoff,
  plus the drop‑replace filter guards).
* Self‑test: **all 6 players live**, embedded, starting **muted**.
* Drop‑replace self-test: **dropping a new video onto a cell replaces and plays
  it** in place while the other five cells keep playing (4/4 checks pass).

## Prerequisites
* VLC at `/Applications/VLC.app` (this machine has 3.0.23 "Vetinari").
