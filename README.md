# sixplayer
Open **6 videos at once**, fill the whole main screen with a **3×2 grid**, and
**nudge each one individually with one key**. Every video **starts muted**; one
key unmutes any of them. Powered by the VLC that already ships with
`/Applications/VLC.app` (`libVLC` 3.0.23) — no extra install.

## Run it

```sh
~/vlc6/run.sh
```

With no arguments it picks 6 random video files directly from `~/Downloads`
and starts them together. If there are more than 6 videos, each launch shuffles
the choice.

A cheat sheet overlays for 9 seconds then hides (**Esc** re‑shows it). The window
fills the main display, joins all spaces, and stays on top until **q** / **Cmd‑Q**.
Click the screen once after it appears so it has keyboard focus.

## Build In Xcode

Open `sixplayer.xcodeproj` in Xcode, select the `sixplayer` scheme, then build or
run it. The app target links against the VLC libraries inside
`/Applications/VLC.app`, so keep VLC installed there.

The command-line launcher also builds through the Xcode project:

```sh
~/vlc6/run.sh
```

## Key map — each video owns one home‑row letter

| Cell | Key | Forward (+) | Backward (−) | Mute ⇄ On |
|:---:|:---:|:---:|:---:|:---:|
| 1 | **A** | `A`           | `Shift+A` | `Option+A` |
| 2 | **S** | `S`           | `Shift+S` | `Option+S` |
| 3 | **D** | `D`           | `Shift+D` | `Option+D` |
| 4 | **F** | `F`           | `Shift+F` | `Option+F` |
| 5 | **G** | `G`           | `Shift+G` | `Option+G` |
| 6 | **H** | `H`           | `Shift+H` | `Option+H` |

* A plain letter = **forward** a "medium" skip (default **10 s**).
* `Shift+` letter = **backward** the same skip.
* `Option+` letter = **toggle that video's sound** (muted ⇄ playing audio).
* `q` or **Cmd‑Q** quit · `Esc` show/hide cheat sheet.
* Change the skip length with `SKIP=5 ~/vlc6/run.sh`.

Cells are numbered `1→6`, left‑to‑right, top‑to‑bottom:
```
+------+------+--------+
|  1   |  2   |  3     |     a    s    d
|  A   |  S   |  D     |
+------+------+--------+
|  4   |  5   |  6     |     f    g    h
|  F   |  G   |  H     |
+------+------+--------+
```

## Choosing the 6 videos (priority order)
1. **Command line:** pass up to 6 video paths to `~/vlc6/run.sh`.
2. **Default:** 6 random video files from `~/Downloads`.

Recognized default video extensions include `mp4`, `m4v`, `mov`, `mkv`, `avi`,
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
`selftest` uses the same dynamic video selection as normal launch and verifies that all
6 players enter the playing state.

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
* **Header‑drift proof:** the only libVLC symbols are declared via `extern` directly in
  the source, so the build is independent of which version of `libvlc.h` is installed.

## Layout
| File | What |
|---|---|
| `run.sh`      | build (if stale) + launch; supports `selftest` / `render` / `SKIP=` / path args |
| `sixplayer.m` | the app (Objective‑C + Cocoa, ARC) |
| `sixplayer.xcodeproj` | Xcode project for building the app bundle |

## Verification done
* Compiles clean on Apple Silicon, links `libvlc.dylib`/`libvlccore.dylib` from the
  system VLC via `@rpath`.
* Self‑test: **all 6 players live**, embedded, starting **muted**.

## Prerequisites
* VLC at `/Applications/VLC.app` (this machine has 3.0.23 "Vetinari").
