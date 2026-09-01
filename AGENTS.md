# AGENTS.md

## Indentation rule: 4 spaces, always

**Indent with 4 spaces. No tabs. No other width. This is the one, permanent
standard for this repository -- keep using it forever, and do not "improve" it,
reformat to another width, or leave code at 2/8/whatever. When adding or changing
a line, match the surrounding 4-space nesting.**

The reason is that different agents and humans guess the indentation width
differently (tabs vs 2 vs 3 vs 8), which produces noisy, merge-conflicting
diffs. A single stated rule removes that guessing.

### For local LLM agents

Do not infer, sample, or guess indentation width from nearby lines. The rule is
fixed and repository-wide: 4 spaces per indentation level, every time. If a
touched line or block uses a different width, normalize it to this rule instead
of preserving the wrong width.

### The standard

- Every indentation level is exactly **4 spaces** (level 1 = 4, level 2 = 8, ...).
- **Never use a tab to indent.** Leading whitespace is spaces only.
- **No hidden / non-ASCII characters.** No non-breaking spaces, no zero-width or
    soft-hyphen characters, no em-dashes/arrows/curly quotes in source. Source
    stays plain ASCII.
- On every non-empty line the leading whitespace must be a **whole multiple of 4**
    spaces.

### Applies to
All human-maintained source: the Objective-C app (`sixplayer.m`), launch scripts
(`run.sh`, `scripts/package_app.sh`), and `Info.plist`.

### Deliberate exceptions -- do NOT reformat these

- **`Makefile`**: GNU Make *requires* recipe command lines to begin with a **tab**.
    Those tabs are a language requirement, not a style choice, so they stay.
- **`sixplayer.xcodeproj/project.pbxproj`**: generated and maintained by Xcode. Do
    not hand-edit, hand-indent, or normalise it.

### Verify before you commit
For each human-maintained file, every line must have leading whitespace of 0 or a
multiple of 4 spaces, contain **no tab**, and contain **no non-ASCII / hidden
character** (the only tabs in the repo live in `Makefile` recipes by necessity).
Run `make whitespace` before committing to check this mechanically.
