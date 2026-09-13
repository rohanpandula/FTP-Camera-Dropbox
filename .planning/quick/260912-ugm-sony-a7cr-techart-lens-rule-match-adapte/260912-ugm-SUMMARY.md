---
quick_id: 260912-ugm
phase: quick
plan: 01
subsystem: sorter
tags: [bash, exiftool, sony, arw, lens-metadata, panel-rules]

requires:
  - phase: feat/panel-density
    provides: panel lens_rules config schema, massage_nef_lens hook, apply_lens_writes validation
provides:
  - ".arw routed into the post-move lens massage hook (identity rewrite only, no render queue)"
  - "LensModel + FocalLength fallback signature for bodies that write no Composite:Lens"
  - "queue_lens_question gated to the Composite:Lens path so native glass never asks"
  - "harness case covering adapted-vs-native Sony glass (unexecuted — Linux only)"
  - "panel rule form documents the Sony signature format"
affects: [deployment, panel lens rules, any future non-Nikon body]

tech-stack:
  added: []
  patterns:
    - "Fallback EXIF signature: build <LensModel> <focal>mm only when the primary read is empty, and mark the path so downstream behavior can differ"

key-files:
  created: []
  modified:
    - sort.sh
    - tests/parallel-sort.sh
    - panel/index.html

key-decisions:
  - "Separate arw) case arm instead of nef|nrw|arw) with a conditional — fewer branches, and the Sony path must not queue renders"
  - "Kept massage_nef_lens and NEF_LENS_MASSAGE names; rename is a large diff for zero behavior change (marked # ponytail:)"
  - "ask=0 on the fallback path: the LensModel read sees every native Sony lens, and native glass must never raise a panel question"
  - "-n deliberately NOT added to the existing -Lens -s3 read: it would print the Nikon signature as '40 40 2 2' and break every live rule"

patterns-established:
  - "Unrunnable-harness compensation: extract the function under test from sort.sh by line range and drive it against real exiftool fixtures on the host"

requirements-completed: [quick-260912-ugm]

duration: 9min
completed: 2026-09-12
---

# Quick 260912-ugm: Sony a7CR Techart lens rule Summary

**Techart LM-EA9 frames off the a7CR now match a panel lens rule by LensModel + focal length, because `.arw` reaches the massage hook at all and no longer needs the Composite:Lens tag Sony never writes.**

## Performance

- **Duration:** ~9 min
- **Started:** 2026-09-13T05:03:17Z
- **Completed:** 2026-09-13T05:12:27Z
- **Tasks:** 2 of 2
- **Files modified:** 3

## Accomplishments

- Fixed both halves of the root cause in one commit: `.arw` never reached `massage_nef_lens`, and even if it had, the function bailed at its empty-`Lens` guard because exiftool only derives `Composite:Lens` from Nikon maker notes.
- The already-live panel rule on tower (`match_lens: ["TECHART LM-EA9 40mm"]`) is now reachable — verified by running the real edited function against a real exiftool fixture and watching it emit `lens: techart.arw -> Minolta M-Rokkor 40mm f2`.
- Native Sony glass is provably untouched and never queues a panel question, which is the regression the `ask` gate exists to prevent.
- Nikon NEF path proven byte-for-byte unchanged by extracting and `cmp`-ing every protected function between the base commit and HEAD.

## Task Commits

1. **Task 1: Match adapted lenses on Sony bodies by LensModel + focal length** — `6c5a146` (fix, with its harness case in the same commit)
2. **Task 2: Document the Sony lens signature in the panel rule form** — `c6e50c0` (docs)

Base commit: `e441fecd581b0b3dc0f387b1c3353b7350a99494`. Branch: `worktree-agent-a676395740956fd67` (worktree of `feat/panel-density`).

## What Changed

`sort.sh`, three edits totalling +42/-3:

1. New `arw)` arm in the post-move `case "${ext,,}"` block (line ~1931), under the same `truthy "$NEF_LENS_MASSAGE"` gate as `nef|nrw)`, with **no** `queue_nef_for_render` call — nef-watch renders NEFs, so Sony gets the identity rewrite and nothing else.
2. `massage_nef_lens`: the bare `[[ -n "$lens" ]] || return 0` guard became an `if [[ -z "$lens" ]]` fallback block that does one extra read (`exiftool_read -T -LensModel -FocalLength -n`), splits it on tab, rejects `-` (what `-T` prints for a missing tag), appends `${focal}mm` when a focal length is present, and sets `ask=0`.
3. The `queue_lens_question` call site wrapped in `if (( ask )); then ... fi`. The call itself, and the whole "a parseable config with no matching rule is authoritative" semantics, are unchanged.

`tests/parallel-sort.sh`, +77: one appended PASS case (case 49) covering both halves — adapted glass rewritten, native glass untouched and unqueued. Uses the real exiftool (no `fast-metadata` or `concurrent-validator` stub on PATH, since the tag reads are the thing under test) and a 264-byte minimal little-endian TIFF that exiftool validates as `FileType: ARW`.

`panel/index.html`, 1 line: the "Match Lens values" field-help now names the Sony signature format with the working example.

## Verification

### Run locally and passing

| Check | Command | Result |
|---|---|---|
| Bash syntax, both files | `/opt/homebrew/bin/bash -n sort.sh && /opt/homebrew/bin/bash -n tests/parallel-sort.sh` | clean |
| Panel static contract | `bash tests/panel-static.sh` | `panel static checks passed` |
| Help text present | `grep -Fq 'match LensModel + focal length, e.g. TECHART LM-EA9 40mm.' panel/index.html` | found |
| New case arm present | `grep -n 'arw)' sort.sh` | `1931:      arw)` |
| Signature derivation | `scratchpad/sig-check.sh` | `SIGCHECK PASSED` |
| Write/readback strings | `scratchpad/writeback-check.sh` | `WRITEBACK CHECK PASSED` |
| Fixture clears validators | `scratchpad/container-check.sh` | `CONTAINER CHECK PASSED` |
| **Real function, real fixtures** | `scratchpad/massage-unit.sh` | `MASSAGE UNIT: ALL PASSED` (11 assertions) |
| Protected regions unchanged | `scratchpad/unchanged-check.sh` | `UNCHANGED CHECK PASSED` (12 assertions) |

The plan's six `<verified_facts>` were all re-confirmed against host exiftool 13.55 rather than taken on trust:

1. A Sony-tagged fixture returns nothing from `exiftool -Lens -s3` → the fallback is the only reachable path.
2. `exiftool -T -LensModel -FocalLength -n` prints `TECHART LM-EA9\t40` → signature `TECHART LM-EA9 40mm`.
3. A missing tag prints `-`; a file with LensModel but no FocalLength yields the bare model; a file with neither bails instead of signing `-`.
4. The live tower rule, fed through the sorter's own jq matcher with `camera="SONY ILCE-7CR"`, selects `Minolta M-Rokkor 40mm f2`.
5. `exiftool -validate -warning -error -a` (the exact `raw_container_validate` invocation) returns `Validate: OK` rc=0 on the 264-byte fixture, and reports `FileType: ARW`.
6. `apply_lens_writes`' arg shape writes back exactly `Minolta M-Rokkor 40mm f2\t40 40 2 2` and leaves no `_original` sidecar.

Because the Linux harness cannot run here, the strongest available substitute was used: `scratchpad/massage-unit.sh` extracts `massage_nef_lens` **and the helpers it calls** verbatim from the committed `sort.sh` by line range, shims only the two GNU tools macOS lacks (`timeout` → `gtimeout`, `sha256sum` → `shasum -a 256`), and exercises the real function against real exiftool fixtures:

- adapted Techart fixture → logs `lens: techart.arw -> Minolta M-Rokkor 40mm f2`, tags read back rewritten, `FNumber` untouched (identity tags only)
- native `FE 35mm F1.4 GM` → no log output, LensModel untouched, no pending question file
- no lens tags at all → silent bail
- same adapter on an `ILCE-7M4` → `match_camera` still gates the fallback, no rewrite
- `lens_massage: false` → nothing happens
- **Nikon regression, with only the `-Lens -s3` read stubbed** (Composite:Lens needs maker notes that cannot be synthesized): rule match still fires, the unmatched-signature ask path still queues a question (`ask=1` default intact), and the built-in `case` still fires when no config exists

### NOT run — still pending

**`tests/parallel-sort.sh` has not been executed, and the new case (case 49) is therefore unexecuted.** The harness is Linux-only and must run inside the sorter image; ssh to tower was blocked for this session and no docker command was run. Its assertion *strings* were each verified independently against real exiftool output (`writeback-check.sh`, `container-check.sh`), and the behavior it asserts was verified through `massage-unit.sh`, but the case itself has never been executed end to end with a live sorter, inotify, the mover, and the validators in the loop.

What only the real harness can still catch:
- the `arw)` arm actually firing from `process()` (the unit suite calls `massage_nef_lens` directly)
- `get_camera` really producing a string containing `ILCE-7CR` on the fixture
- the fixture surviving stability checks, `validate_file`, and `move_with_suffix` end to end
- the sorted path really being `2026-09-12/raw/`

Required next step before deploy: `tests/run-on-tower.sh tests/parallel-sort.sh` (human-gated; also re-confirms the other 48 cases still pass).

Nothing was deployed. No container, NAS path, or docker command was touched.

## Deviations from Plan

Plan executed as written, with two additions:

**1. [Rule 2 — diagnostics] `|| fail` on the two harness fixture-tagging calls**
- **Found during:** Task 1(c)
- **Issue:** the harness runs under `set -euo pipefail`. An unguarded `exiftool` failure while building a fixture would kill the run with a bare `exit 1` and no message, on a Linux box I cannot reach to debug.
- **Fix:** appended `|| fail "could not tag the adapted-lens fixture"` / `... native-lens fixture` so the failure names itself.
- **Commit:** `6c5a146`

**2. [Verification depth] Host-side unit exercise of the real function**
- The plan's automated verification asked for a scratchpad re-implementation of the three signature lines. That only tests the scratchpad copy, not the committed code. Replaced it with `massage-unit.sh`, which extracts and runs the committed function itself, and added the three Nikon regression assertions the plan asserts by inspection (`git diff` review) but does not execute. Scratchpad-only; nothing added to the repo.

## Threat Flags

None. The new fallback signature is camera-controlled input, and the plan's register already dispositions it:

- **T-quick-02 holds as designed.** The signature reaches jq only as `--arg lens` (exact `index()` compare, never interpolated into a filter) and, on the fallback path, never reaches `queue_lens_question` or any log line — confirmed by the unit run, where native and tagless Sony fixtures produced zero log output. The only string logged is the *rule's* `lens_model`, which `apply_lens_writes` re-validates against `model_re` and which this plan does not touch.
- **T-quick-03 accepted as planned.** One extra `exiftool_read` per non-Nikon RAW, only when `Composite:Lens` is empty, inside the existing `timeout -k 2 "$RAW_VALIDATE_TIMEOUT"` wrapper.
- No package installs, no new dependencies.

## Known Stubs

None in shipped code. The `massage-unit.sh` Nikon test stubs the `-Lens -s3` read, but that lives in the session scratchpad, not the repo, and is the only way to test a Nikon path without synthesizable maker notes.

## Commit Trailer

The executor wrote an Opus 5 trailer; the orchestrator rebased both commits onto `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` before the merge (hashes above are post-rebase).

## Self-Check: PASSED

- `sort.sh` — FOUND, modified, `bash -n` clean, `arw)` arm at line 1931
- `tests/parallel-sort.sh` — FOUND, modified, `bash -n` clean, new case appended after the profile-sidecar case
- `panel/index.html` — FOUND, modified, 1 line, `tests/panel-static.sh` passes
- `6c5a146` — FOUND in `git log`
- `c6e50c0` — FOUND in `git log`
- No file deletions in either commit (`git diff --diff-filter=D HEAD~1 HEAD` empty for both)
- Working tree clean apart from this SUMMARY
