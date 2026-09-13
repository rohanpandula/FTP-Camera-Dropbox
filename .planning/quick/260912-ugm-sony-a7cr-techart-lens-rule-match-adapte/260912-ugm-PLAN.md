---
quick_id: 260912-ugm
phase: quick
plan: 01
type: execute
wave: 1
depends_on: []
files_modified: [sort.sh, tests/parallel-sort.sh, panel/index.html]
autonomous: true
requirements: [quick-260912-ugm]
user_setup: []

must_haves:
  truths:
    - "A Techart LM-EA9 ARW from the a7CR gets its lens identity rewritten from the panel rule (log line `lens: techart.arw -> Minolta M-Rokkor 40mm f2`)."
    - "A native Sony ARW sorts with its LensModel untouched and never queues a panel question."
    - "Nikon NEF lens matching (Composite:Lens signature, LensID regex, question queue) is unchanged."
    - "The panel rule form tells the operator the signature format for bodies that write no Lens tag."
  artifacts:
    - path: "sort.sh"
      provides: "`arw)` arm in the post-move case block + LensModel/FocalLength fallback signature in massage_nef_lens"
      contains: "arw)"
    - path: "tests/parallel-sort.sh"
      provides: "PASS case: adapted Sony lens matched, native Sony glass untouched and never asked"
      contains: "TECHART LM-EA9 40mm"
    - path: "panel/index.html"
      provides: "field-help naming the Sony signature format"
      contains: "LensModel + focal length"
  key_links:
    - from: "sort.sh case block (~line 1894)"
      to: "massage_nef_lens"
      via: "new arw) arm under truthy \"$NEF_LENS_MASSAGE\", no queue_nef_for_render"
      pattern: "arw\\)"
    - from: "massage_nef_lens"
      to: "exiftool"
      via: "single fallback read when Composite:Lens is empty"
      pattern: "\\-T \\-LensModel \\-FocalLength \\-n"
    - from: "tests/parallel-sort.sh new case"
      to: "real exiftool"
      via: "no fast-metadata / concurrent-validator fixture dir on PATH for this case"
      pattern: "RAW_MIN_BYTES_SONY_A7CR=1"
---

<objective>
Techart LM-EA9 shots from the a7CR sort with the adapter's identity ("TECHART LM-EA9", LensInfo "40 40 2.8 2.8") and no lens rule can ever fire: Sony writes no Composite:Lens tag (exiftool only builds that from Nikon maker notes), and `.arw` never reached `massage_nef_lens` in the first place. Fix both halves with the shortest diff: route `.arw` into the existing massage hook, and when Composite:Lens is empty build the signature from LensModel + FocalLength (the only tag that tells the M lenses apart on this adapter).

Purpose: the operator's Leica/Minolta M glass lands in Lightroom named correctly instead of as a Canon EF 40mm.
Output: `sort.sh` (two small edits), one new harness case, one line of panel help text. Two commits.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md

Branch: stay on `feat/panel-density`. Do NOT deploy, do NOT touch tower/the NAS, do NOT ssh anywhere.
Ponytail: shortest diff that fixes the root cause, no new abstractions, comments explain the observed failure (why), not the what.
Commit trailer for both commits:
`Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`
</execution_context>

<context>
@./CLAUDE.md
@.planning/STATE.md

Read before editing (line numbers verified 2026-09-12):
- `sort.sh` 1064-1089 `apply_lens_writes` (re-validates every rule field; unchanged by this plan)
- `sort.sh` 1091-1170 `massage_nef_lens` (the read at 1109-1111, the config match at 1113-1141, the no-match queue at 1142-1148, the built-in Nikon `case` at 1151-1168)
- `sort.sh` 1172-1202 `queue_lens_question`
- `sort.sh` 1889-1905 the post-move `case "${ext,,}" in nef|nrw)` block
- `tests/parallel-sort.sh` 2684-2757 the profile-sidecar case (the template; it is the LAST case in the file, which ends at line 2757 with `stop_sorter` — the new case is appended after it)
- `tests/parallel-sort.sh` 156-230 helpers (`fail`, `wait_for_log`, `assert_log_absent_for`), `stop_sorter`, and the header vars `ROOT` / `SORTER` / `TEST_ROOT` (lines 4-13)
- `panel/index.html` 1471 the "Match Lens values" label

<interfaces>
Contracts the executor must match exactly — no exploration needed.

`sort.sh:1107-1111` (current, the spot Task 1b edits):
  local f=$1 base=$2 camera=${3:-} lens lensid rule idre
  panel_flag lens_massage || return 0
  lens=$(exiftool_read -Lens -s3 "$f") || lens=""
  lens=${lens%%$'\n'*}
  [[ -n "$lens" ]] || return 0

`sort.sh:681` exiftool_read() { timeout -k 2 "$RAW_VALIDATE_TIMEOUT" exiftool "$@" 2>/dev/null; }
`sort.sh:1044` exiftool_write() { timeout "$RAW_VALIDATE_TIMEOUT" exiftool -q -q -overwrite_original "$@" 2>/dev/null; }  -> no `_original` file is left behind
`sort.sh:1085` log "lens: $base -> ${model:-focal ${focal}mm}"  -> the log line the harness waits for
`sort.sh:1142-1148` the no-match branch: comment says "A parseable config with no matching rule is authoritative: no fallback" then `queue_lens_question "$f" "$base" "$lens" "$camera"; return 0`
`sort.sh:1151` built-in fallback `case "$lens" in "35mm f/1.4") ... "50mm f/1.2"|"50mm f/1.3") ... "0mm f/0")`
`sort.sh` jq matcher: `.match_lens | index($lens)` — exact string equality against `$lens`, and `match_camera` is a case-insensitive *substring* test against the sanitized camera string
`sort.sh:666` extension map: `raf|arw|nef|cr2|cr3|dng|orf|rw2|pef|srw) echo raw`
`sort.sh:698-703` raw_min_bytes_for uses `camera_model` (Model only) -> key "ILCE-7CR:arw" -> RAW_MIN_BYTES_SONY_A7CR (default 40 MB)
`sort.sh:2` `set -u` only — no `-e`, no `pipefail`; a `read` that hits EOF returning 1 is harmless
</interfaces>

<verified_facts>
Verified against real a7CR files on the NAS with exiftool 13.55. Do NOT re-litigate, do NOT "improve":
1. Sony ARW carries NO Composite:Lens: `exiftool -Lens -s3 DSC02249.ARW` prints nothing, so `massage_nef_lens` returns at `[[ -n "$lens" ]] || return 0` for every Sony file.
2. The Techart LM-EA9 on ILCE-7CR reports fixed LensModel "TECHART LM-EA9", fixed LensInfo "40 40 2.8 2.8", fixed LensID "Canon EF 40mm f/2.8 STM + Canon EF Adapter"; only FocalLength changes with the glass the operator dialed in (40 = Minolta M-Rokkor 40mm f/2, 35 = Leica 35).
3. `exiftool -T -LensModel -FocalLength -n FILE` prints one line `TECHART LM-EA9<TAB>40`; missing tags print `-`.
4. `-n` MUST NOT be added to the existing `-Lens -s3` read: with `-n` the Nikon Composite:Lens prints "40 40 2 2" instead of "40mm f/2" and every existing rule stops matching.
5. The panel validator accepts any printable `match_lens` string — no `panel/app.py` change and no pytest needed. The live panel config on the NAS already holds the rule `{"match_lens":["TECHART LM-EA9 40mm"],"match_camera":["ILCE-7CR"],"lens_model":"Minolta M-Rokkor 40mm f2","lens_info":"40 40 2 2"}`; it is inert until this sorter change ships.
6. The Linux harness cannot run on this Mac and ssh to the NAS is blocked from this session. Local tools: `/opt/homebrew/bin/bash` (5.3), `/opt/homebrew/bin/exiftool` (13.55), `/opt/homebrew/bin/gtimeout`, `/usr/bin/jq`. The tower harness run stays PENDING and must be stated plainly in the SUMMARY.
</verified_facts>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Match adapted lenses on Sony bodies by LensModel + focal length</name>
  <files>sort.sh, tests/parallel-sort.sh</files>

  <behavior>
    - techart.arw (Make SONY, Model ILCE-7CR, LensModel "TECHART LM-EA9", FocalLength 40) + the panel rule above -> sorter logs `lens: techart.arw -> Minolta M-Rokkor 40mm f2`; the sorted file reads LensModel "Minolta M-Rokkor 40mm f2", LensInfo "40 40 2 2".
    - native.arw (same body, LensModel "FE 35mm F1.4 GM", FocalLength 35) -> sorts normally, no `lens: native.arw` line, LensModel unchanged, nothing under `data/.panel/pending/`.
    - Nikon path untouched: Composite:Lens signature, `match_lens_id_regex`, and `queue_lens_question` behave exactly as before.
  </behavior>

  <action>
Three edits, ONE commit.

(a) `sort.sh` post-move case block (~line 1894): add an `arw)` arm beside `nef|nrw)`, calling `massage_nef_lens "$MOVED_DEST" "$moved_log" "$camera"` under the same `truthy "$NEF_LENS_MASSAGE"` gate, with NO `queue_nef_for_render` call — nef-watch renders NEFs only, Sony gets the identity rewrite and nothing else. Say that in the comment. Separate arm, not `nef|nrw|arw)` plus a conditional: fewer branches.

(b) `sort.sh` `massage_nef_lens`: keep the `-Lens -s3` read byte-for-byte (see verified fact 4). Replace the bare `[[ -n "$lens" ]] || return 0` guard with a fallback block that runs only when that read came back empty:
  - add locals `sig focal ask=1` to the existing `local` line;
  - one read: `sig=$(exiftool_read -T -LensModel -FocalLength -n "$f") || sig=""`, then `sig=${sig%%$'\n'*}`;
  - split with `IFS=$'\t' read -r lens focal <<<"$sig"`;
  - `[[ -n "$lens" && "$lens" != "-" ]] || return 0`;
  - if FocalLength is present and not `-`, append it: `lens="$lens ${focal}mm"` (inside an explicit `if ... then ... fi`, not a `&&` tail) — signature "TECHART LM-EA9 40mm"; bare LensModel when there is no focal length;
  - set `ask=0` to mark the fallback path.
  Then, in the no-match branch (~line 1145), keep the existing `if jq -e '.lens_rules | type == "array"' ...; then ... return 0; fi` shape and its "authoritative: no fallback" semantics intact, but wrap only the `queue_lens_question` call in `if (( ask )); then ... fi`. Reason for the gate, in the comment: the LensModel fallback sees every native Sony lens too, and native glass must never raise a panel question — the ask flow exists for dumb Nikon adapters.
  Do NOT rename `massage_nef_lens` or `NEF_LENS_MASSAGE` (rename = large diff, zero behavior change); instead note the widened scope in the function's existing comment block. Everything downstream (`apply_lens_writes` field re-validation, `match_lens_id_regex` timeout, the built-in Nikon `case`) stays untouched. Comments cite the observed failure (facts 1-3), not the mechanics.

(c) `tests/parallel-sort.sh`: append one new PASS-printing case at the end of the file (after the profile-sidecar case's `stop_sorter`), modeled on that case. Use the REAL exiftool — do NOT put `tests/fixtures/fast-metadata` or `tests/fixtures/concurrent-validator` on PATH for this case; both stub exiftool and would defeat the test.
  - `rm -rf "$TEST_ROOT/data"`, `mkdir -p "$TEST_ROOT/data/incoming" "$TEST_ROOT/data/.panel"`, `: > "$TEST_ROOT/sorter.log"`.
  - config.json heredoc: `{"features": {"lens_massage": true, "ask_on_unknown": true}, "lens_rules": [{"match_lens": ["TECHART LM-EA9 40mm"], "match_camera": ["ILCE-7CR"], "lens_model": "Minolta M-Rokkor 40mm f2", "lens_info": "40 40 2 2"}]}`.
  - fixture, inline (no new helper, it is two printf+exiftool pairs): `printf 'II*\0\x08\0\0\0\x01\0\x00\x01\x03\0\x01\0\0\0\x01\0\0\0\0\0\0\0' > "$TEST_ROOT/data/incoming/techart.arw"` then `exiftool -q -q -overwrite_original -Make=SONY -Model=ILCE-7CR -LensModel="TECHART LM-EA9" -FocalLength=40 -LensInfo="40 40 2.8 2.8" -FNumber=2 -DateTimeOriginal="2026:09:12 10:00:00" "$TEST_ROOT/data/incoming/techart.arw"` then `touch -d '2 minutes ago'` it. This minimal TIFF passes `exiftool -validate`.
  - env block: `INCOMING`/`SORTED`/`QUARANTINE`/`PANEL_CONFIG` as in the template, plus `NEF_LENS_MASSAGE=1 STABLE_WAIT=1 STABLE_SKIP_AGE=1 SORT_WORKERS=1 RECONCILE_IDLE=30 NOTIFY_INTERVAL=3600 RAW_MIN_BYTES_DEFAULT=1 RAW_MIN_BYTES_SONY_A7CR=1 RAW_VALIDATE_TIMEOUT=60 RAW_FULL_VALIDATE=0 TG_CONFIG="$TEST_ROOT/telegram.json"`, launching `/bin/bash "$SORTER"` into `$TEST_ROOT/sorter.log` with `SORTER_PID=$!`. Both byte knobs are needed (`raw_min_bytes_for` keys on "ILCE-7CR:arw"); `RAW_FULL_VALIDATE=0` skips raw-identify/simple_dcraw, which a 24-byte TIFF cannot satisfy.
  - assertions, each with a `|| fail "..."` message naming the real failure: `wait_for_log 'lens: techart.arw -> Minolta M-Rokkor 40mm f2' 60`; then `exiftool -T -LensModel -LensInfo -n "$TEST_ROOT/data/sorted/2026-09-12/raw/techart.arw"` equals `$'Minolta M-Rokkor 40mm f2\t40 40 2 2'`.
  - then drop native.arw (same printf; same exiftool flags except `-LensModel="FE 35mm F1.4 GM" -FocalLength=35 -LensInfo="35 35 1.4 1.4"`; same `touch -d '2 minutes ago'`) and assert: `wait_for_log 'ok: native.arw -> 2026-09-12/raw/native.arw' 60`; `assert_log_absent_for 'lens: native.arw' 3`; `exiftool -T -LensModel -n` on the sorted native.arw equals `FE 35mm F1.4 GM`; `[[ -z $(find "$TEST_ROOT/data/.panel/pending" -type f 2>/dev/null) ]]`.
  - end with `echo "PASS: Sony adapted lens matched by LensModel + focal length; native glass untouched and never asked"` then `stop_sorter`.

Commit (subject + body; body states the observed failure and the evidence):
`sort.sh: match adapted lenses on Sony bodies by LensModel + focal length`
Body: Techart LM-EA9 frames from the a7CR sorted with the adapter's identity — Sony writes no Composite:Lens (exiftool builds that tag from Nikon maker notes only) and `.arw` never reached the massage hook, so no panel rule could fire. The adapter reports a fixed LensModel/LensInfo/LensID; FocalLength is the only tag that separates the M lenses. Harness case in the same commit. Note in the body that the Linux harness run on tower is still pending.
  </action>

  <verify>
    <automated>/opt/homebrew/bin/bash -n sort.sh &amp;&amp; /opt/homebrew/bin/bash -n tests/parallel-sort.sh</automated>
    <automated>Signature check on the real fixture, run from the scratchpad with host exiftool: build techart.arw with the printf+exiftool recipe above, then assert (1) `exiftool -Lens -s3` prints nothing (the fallback is reached), (2) `sig=$(exiftool -T -LensModel -FocalLength -n f); IFS=$'\t' read -r lens focal &lt;&lt;&lt;"$sig"; lens="$lens ${focal}mm"` yields exactly `TECHART LM-EA9 40mm`, and (3) the same three lines against a LensModel-only file yield the bare model. Script exits non-zero on any mismatch.</automated>
    <automated>grep -n 'arw)' sort.sh  # the new arm exists in the post-move case block</automated>
    <human-check>Linux harness (`tests/run-on-tower.sh tests/parallel-sort.sh`) — NOT runnable from this session (ssh to the NAS blocked); record as pending in the SUMMARY.</human-check>
  </verify>

  <done>`arw)` arm present with no render-queue call; `massage_nef_lens` builds the "&lt;LensModel&gt; &lt;focal&gt;mm" signature only when Composite:Lens is empty and skips `queue_lens_question` on that path; the `-Lens -s3` read and the whole Nikon path are unchanged (`git diff` shows no edit inside the config-match block, the idre block, or the built-in `case`); new harness case appended; both files pass `bash -n`; the signature check passes against a real fixture; one commit with the subject above.</done>
</task>

<task type="auto">
  <name>Task 2: Document the Sony lens signature in the panel rule form</name>
  <files>panel/index.html</files>
  <action>
Line 1471, the "Match Lens values" field-help: extend `Comma-separated exact EXIF Lens strings.` with ` Bodies that write no Lens tag (Sony) match LensModel + focal length, e.g. TECHART LM-EA9 40mm.` Nothing else changes — no `panel/app.py`, no placeholder change, no new markup.

The text lives inside a JS template literal that `tests/panel-static.sh` parses with `node --check`, so: no backticks, no `${`, no `<`/`>`, no `style=`, and no ` onword=` substring (the static test rejects all of those).

Commit: `panel: document the Sony lens signature in the rule form` — body: operators had no way to know the signature format for bodies that write no Lens tag.
  </action>
  <verify>
    <automated>bash tests/panel-static.sh</automated>
    <automated>grep -Fq 'match LensModel + focal length, e.g. TECHART LM-EA9 40mm.' panel/index.html</automated>
  </verify>
  <done>`tests/panel-static.sh` prints "panel static checks passed"; the help text names the signature format; `git diff --stat` for this commit shows only `panel/index.html`, 1 line changed.</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| camera EXIF -> sorter | LensModel/FocalLength are attacker-controllable strings from a LAN-writable `/data/incoming` |
| panel config (no auth, LAN) -> exiftool args | rule fields drive the write |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-quick-01 | Tampering | `apply_lens_writes` args from a mangled config | mitigate | unchanged: every value lands after a fixed `-TAG=` prefix and must match the existing `model_re`/`info_re`/`focal_re` — this plan touches no part of that function |
| T-quick-02 | Injection/Elevation | fallback signature string from camera EXIF | mitigate | the signature is only ever passed to jq as `--arg lens` (exact `index()` compare) and, on the Nikon path only, to `queue_lens_question`, which already `sanitize`s before logging; the fallback path logs nothing |
| T-quick-03 | DoS | extra `exiftool` read per non-Nikon RAW | accept | one read, only when Composite:Lens is empty, through `exiftool_read`'s existing `timeout -k 2 "$RAW_VALIDATE_TIMEOUT"` wrapper |
| T-quick-SC | Tampering | npm/pip/cargo installs | n/a | no package installs in this plan; no new dependencies (stdlib/existing binaries only) |
</threat_model>

<verification>
1. `/opt/homebrew/bin/bash -n sort.sh` and `/opt/homebrew/bin/bash -n tests/parallel-sort.sh` both clean.
2. Signature check against a real minimal ARW fixture passes (Task 1 verify).
3. `bash tests/panel-static.sh` prints "panel static checks passed".
4. `git diff main...HEAD -- sort.sh` shows the `-Lens -s3` read, the config-match block, the `match_lens_id_regex` block, the built-in Nikon `case`, and `apply_lens_writes` unchanged.
5. Two commits, correct subjects, each with the Co-Authored-By trailer; nothing deployed; branch still `feat/panel-density`.
</verification>

<success_criteria>
- An a7CR ARW shot through the LM-EA9 would match the already-live panel rule and be rewritten to "Minolta M-Rokkor 40mm f2" / "40 40 2 2".
- A native Sony ARW is never rewritten and never queues a panel question.
- The Nikon NEF path is byte-for-byte unchanged.
- Harness case committed with the code it covers; tower run recorded as pending in the SUMMARY.
- Panel rule form documents the Sony signature format.
</success_criteria>

<output>
Write `.planning/quick/260912-ugm-sony-a7cr-techart-lens-rule-match-adapte/260912-ugm-SUMMARY.md`. It MUST state plainly that `tests/parallel-sort.sh` has not been run (Linux-only; ssh to tower blocked from this session) and that the new case is unexecuted, alongside what WAS verified locally.
</output>
