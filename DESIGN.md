---
name: FTP Camera Dropbox
description: The Archive Accession Ledger for fast, truthful confidence in self-hosted camera intake.
colors:
  paper: "#e9ece5"
  sheet: "#f8f9f5"
  sheet-2: "#dfe4dc"
  ink: "#171a18"
  ink-soft: "#505751"
  ink-faint: "#6f7771"
  rule: "#aeb5ae"
  rule-dark: "#747b75"
  signal: "#ee3f29"
  signal-dark: "#a61f13"
  signal-fill: "#d52f18"
  link: "#1748c7"
  healthy: "#08744f"
  warning: "#9b4a00"
  danger: "#a61f13"
  focus: "#1748c7"
typography:
  display:
    fontFamily: '"Big Shoulders", "Arial Narrow", sans-serif'
    fontSize: "26px"
    fontWeight: 800
    lineHeight: 1
    letterSpacing: "-0.01em"
  headline:
    fontFamily: '"Big Shoulders", "Arial Narrow", sans-serif'
    fontSize: "16px"
    fontWeight: 750
    lineHeight: 1
    letterSpacing: "0.03em"
  title:
    fontFamily: '"Big Shoulders", "Arial Narrow", sans-serif'
    fontSize: "22px"
    fontWeight: 750
    lineHeight: 1
    letterSpacing: "-0.01em"
  nav:
    fontFamily: '"Big Shoulders", "Arial Narrow", sans-serif'
    fontSize: "15px"
    fontWeight: 750
    lineHeight: 1
    letterSpacing: "0.04em"
  control:
    fontFamily: '"Big Shoulders", "Arial Narrow", sans-serif'
    fontSize: "12px"
    fontWeight: 750
    lineHeight: 1
    letterSpacing: "0.05em"
  body:
    fontFamily: 'ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.45
    letterSpacing: "normal"
  label:
    fontFamily: 'ui-monospace, "SFMono-Regular", Consolas, "Liberation Mono", monospace'
    fontSize: "10px"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "0.08em"
  metadata:
    fontFamily: 'ui-monospace, "SFMono-Regular", Consolas, "Liberation Mono", monospace'
    fontSize: "13px"
    fontWeight: 700
    lineHeight: 1.3
    letterSpacing: "normal"
rounded:
  square: "0"
  control: "2px"
  circular: "50%"
components:
  nav-tab:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    typography: "{typography.nav}"
    rounded: "{rounded.square}"
    padding: "0 20px"
    height: "56px"
  nav-tab-active:
    backgroundColor: "{colors.signal-fill}"
    textColor: "#ffffff"
    typography: "{typography.nav}"
    rounded: "{rounded.square}"
    padding: "0 20px"
    height: "56px"
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.sheet}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "6px 12px"
  button-primary-hover:
    backgroundColor: "{colors.signal-fill}"
    textColor: "{colors.sheet}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "6px 12px"
  button-secondary:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "6px 12px"
  button-danger:
    backgroundColor: "transparent"
    textColor: "{colors.danger}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "6px 12px"
  button-quiet:
    backgroundColor: "transparent"
    textColor: "{colors.link}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "6px 8px"
  field:
    backgroundColor: "{colors.sheet}"
    textColor: "{colors.ink}"
    typography: "{typography.metadata}"
    rounded: "{rounded.control}"
    padding: "6px 10px"
    height: "36px"
  chip:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.square}"
    padding: "5px 8px"
  switch-off:
    backgroundColor: "{colors.sheet-2}"
    textColor: "{colors.ink-soft}"
    typography: "{typography.label}"
    rounded: "{rounded.square}"
    width: "48px"
    height: "26px"
  switch-on:
    backgroundColor: "#f4d3cc"
    textColor: "{colors.signal-dark}"
    typography: "{typography.label}"
    rounded: "{rounded.square}"
    width: "48px"
    height: "26px"
  proof-card:
    backgroundColor: "{colors.sheet}"
    textColor: "{colors.ink}"
    typography: "{typography.metadata}"
    rounded: "{rounded.square}"
  status-strip:
    backgroundColor: "{colors.sheet}"
    textColor: "{colors.ink}"
    typography: "{typography.metadata}"
    rounded: "{rounded.square}"
    padding: "16px"
  attention-list:
    backgroundColor: "{colors.sheet}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.square}"
    padding: "16px clamp(16px, 2.5vw, 32px) 24px"
---

# Design System: FTP Camera Dropbox

## Overview

**Creative North Star: "The Archive Accession Ledger"**

The Archive Accession Ledger turns a self-hosted camera-ingest panel into a contemporary accession sheet: cool archival paper, near-black register ink, ruled metadata, clipped index tabs, and one vermilion thread that makes live intake legible. It is calm and factual rather than celebratory; the operator should know within five seconds whether files are arriving safely and whether anything needs intervention.

The world deliberately rejects both the black camera-body dashboard and the rounded cloud-storage SaaS. Photographs are the proof, controls feel like registry tools, and system state is carried by exact copy, tabular evidence, border structure, and restrained motion.

**Key Characteristics:**

- Cool archival paper with a subtle photographed-paper wash.
- Compressed Big Shoulders display type paired with readable system sans and tabular mono.
- Square ruled cells with selective clipped top-right corners.
- A 56px index bar whose tabs size to their labels, and a mobile bottom index.
- One vermilion thread: the selected tab, the needs-attention rule, and live-arrival marks.
- Aggregate status in one strip and a needs-attention list, without invented per-file progress.

## Colors

The palette is a cool, low-chroma paper-and-ink field interrupted by functional vermilion, evidence blue, monitoring green, and warning amber. The frontmatter values are normative; the implementation keeps separate semantic aliases where two roles currently share one value.

### Primary

- **Intake Vermilion** (`signal`): Marks live-arrival state, the needs-attention rule, the switch block, and the brand mark. `signal-fill` is the deeper vermilion used wherever white text sits on vermilion (active tab, button hover) so the pair reads at 4.9:1.
- **Deep Vermilion** (`signal-dark`): Carries numbered protection marks and darker signal text; the same extracted value is independently exposed as `danger` for destructive or failed states.

### Secondary

- **Evidence Blue** (`link`): Reserved for navigational text links and destinations; the same extracted value is independently exposed as `focus` for keyboard focus.

### Tertiary

- **Monitoring Green** (`healthy`): Communicates clean monitoring evidence.
- **Warning Amber** (`warning`): Frames configuration warnings without borrowing the danger treatment.
- **Danger Red** (`danger`): Identifies failed health, destructive actions, and error feedback.

### Neutral

- **Cool Archive Paper** (`paper`): The outer canvas and sticky header substrate.
- **Accession Sheet** (`sheet`): The primary working surface and component fill.
- **Muted Sheet** (`sheet-2`): Hover, empty, placeholder, and inactive-control surfaces.
- **Register Ink** (`ink`): Primary type and the strongest structural rules.
- **Soft Ink** (`ink-soft`): Supporting copy and secondary metadata.
- **Faint Ink** (`ink-faint`): Placeholders and least-prominent metadata.
- **Register Rule** (`rule`): Quiet row separation.
- **Dark Register Rule** (`rule-dark`): Structural cells, frames, and grid joins.

### Named Rules

**The One Thread Rule.** Vermilion is the single live thread through the system: use it for active intake, the selected index, and genuine attention, never as ambient decoration.

## Typography

**Display Font:** Big Shoulders (with Arial Narrow and sans-serif fallbacks). Self-hosted at `panel/assets/big-shoulders.woff2`, licensed under the SIL Open Font License 1.1 (`panel/assets/OFL-Big-Shoulders.txt`); © The Big Shoulders Project Authors.

**Body Font:** System UI sans

**Label/Mono Font:** System monospace

**Character:** Big Shoulders gives verdicts and register headings the compressed authority of an accession stamp. The system sans remains quiet and readable, while the monospace layer makes filenames, counts, paths, dates, and evidence scan as records rather than marketing copy.

### Hierarchy

The scale is fixed pixels (10, 11, 12, 13, 14, 16, 18, 22, 26), never fluid: the panel is an operating surface viewed at a consistent distance, and a heading that shrinks with the viewport reads as noise, not rhythm.

- **Display** (800, 26px, 1): Page titles (uppercase) and the Now verdict (sentence case, 24px on phones).
- **Headline** (750, 16px, 1, 0.03em): Uppercase section headings; sub-headings inside a section drop to 13px.
- **Title** (750, 22px, 1): Status-strip fact values; row counts use the same face at 18px.
- **Body** (400, 14px, 1.45): Explanations and operational guidance; supporting copy under a heading or row runs 12–13px in soft ink.
- **Label** (700, 10px, 0.08em): Uppercase evidence labels, counters, and field labels.
- **Metadata** (700, 12–13px, 1.3): Filenames, paths, counts, dates, and compact technical facts, with tabular numerals wherever values align; 11px for captions and notes.

### Named Rules

**The Register Voice Rule.** Use Big Shoulders for hierarchy, system sans for explanation, and monospace only where the content behaves like a record.

## Layout

The shell is a centered ledger no wider than 1440px, framed by one-pixel rules. A 56px sticky index bar holds the wordmark, the four tabs, and live status. The Now view stacks, in reading order: a status strip (the verdict cell plus four evidence cells), an In Intake list only while files are arriving, a needs-attention list only while something needs a decision, recent proof six across, and a collapsed protection note. Every other view is a one-line page head followed by ruled rows.

Spacing uses a 4px scale (4, 8, 12, 16, 24, 32): 6–8px inside a row, 12px under a heading, 16px of section padding, 24px after a section's last row. Page gutters are `clamp(16px, 2.5vw, 32px)`. Rows are at least 44px tall so every list is already a touch target. Preserve the dense register rhythm instead of inserting isolated floating cards.

At 1099px the verdict spans the strip and the four facts sit beneath it; proof becomes four columns. At 760px the tabs move into a fixed 60px bottom bar, facts form a 2×2 grid, proof is three across, forms stack, and controls grow to 44px. At 440px action rows stack while the three-column contact sheet remains.

### Named Rules

**The Four-Tab Rule.** Now, Library, Attention, and Automations always appear in that order; on desktop each tab sizes to its label, and on small screens the same index moves intact to the bottom edge and shares the width equally.

## Elevation & Depth

This is a flat system with no surface elevation or card shadow vocabulary. Depth comes from the difference between paper, sheet, and muted-sheet tones; a 512px archival-paper texture under translucent paper washes; one-pixel structural rules; and the overlap created by clipped tabs and registers.

### Named Rules

**The Flat Ruled Rule.** Separate surfaces with paper tone, line weight, and shared edges; never lift routine panels with shadows.

## Shapes

Square is the default silhouette. Buttons and fields permit only a restrained 2px radius; the rectangular switch is explicitly square. True circles are reserved for the status dot and the camera mark.

Clipping supplies the signature geometry: the active index tab loses a 10px top-right corner. Structural borders are one pixel; the needs-attention list opens with a 3px vermilion rule; thumbnails and ledger cells stay square.

### Named Rules

**The Clipped Accession Rule.** Use one deliberate top-right cut to mark selection or exception; do not substitute rounded cards, pill controls, or ornamental corner systems.

## Components

### Buttons

- **Shape:** Registry rectangle with a 1px ink border and a restrained 2px radius; 32px minimum height on desktop and 44px on mobile.
- **Primary:** Near-black ink fill with accession-sheet text and `6px 12px` padding; hover switches to the deeper vermilion fill and active presses down by 1px.
- **Secondary:** Transparent sheet with register-ink text; hover fills with the muted sheet.
- **Danger:** Transparent danger border and text; hover fills danger red and reverses the label to white.
- **Quiet:** Borderless evidence-blue action; hover gains a muted-sheet field and dark ink. Mobile quiet actions still present a 44px target.
- **Focus / Disabled:** The global focus treatment is a 3px evidence-blue outline with 2px offset. Disabled controls retain their form at 48% opacity and use a waiting cursor.

### Chips

- **Style:** Square, one-pixel register border, compact monospace label, and `6px 8px` desktop padding.
- **State:** Removal is a separate danger-colored button; on mobile that button becomes a 44px square target while the text half remains compact.

### Cards / Containers

- **Corner Style:** Square by default; proof thumbnails and captions share hard edges.
- **Background:** Accession sheet over a muted-sheet media placeholder.
- **Shadow Strategy:** None; cards join through one-pixel dark rules.
- **Internal Padding:** Proof captions use `8px 10px 10px`, compacting to `6px 8px 8px` on mobile.
- **Behavior:** Proof media stays 4:3. On Now the image itself is a button that opens the capture-date folder; hover scales it to 1.02. Filename, media type, time, and the capture date remain visible evidence.

### Inputs / Fields

- **Style:** Accession-sheet fill, one-pixel dark register border, 2px radius, monospace value, `6px 10px` padding, and a 36px minimum height (44px on mobile).
- **Focus:** Border changes to evidence blue and gains a 3px translucent blue outline.
- **Placeholder:** Faint ink at full opacity. Labels remain uppercase 10px monospace.

### Navigation

Uppercase Big Shoulders tabs sit in the 56px index bar, each sized to its label. Hover uses the muted sheet; the active tab uses the deeper vermilion fill, white text, `aria-current="page"`, and the clipped top-right corner. Attention may carry a small bordered monospace count. Below 760px, the same four tabs become a fixed 60px bottom index while the compact header retains brand and aggregate status.

### Aggregate Status and Verdict

The chrome computes inbound work as receiving plus files waiting or checking. Attention is active quarantine plus pending lens decisions, with one additional item when health has failed. Failed health takes precedence, then inbound work, then unresolved attention, then the clean monitoring state. The one-line verdict follows the same order and shares the status strip with four evidence cells: pipeline, in intake (receiving plus checking), filed today, and free space. Status always includes text and a polite spoken label; color is never the only cue.

### Status Strip

One ruled row: the verdict cell (two columns wide) and four fact cells, each with a 10px label, a 22px value, and an 11px monospace detail that may wrap to a second line rather than truncate. While inbound work is nonzero an In Intake section lists the files still settling with size and arrival age; it never represents per-file progress.

### Needs-Attention List

When health has failed, files are held, or lens decisions are pending, a section opens under a 3px vermilion rule with one 44px row per category; each row is a link into Attention and carries its consequence copy. When nothing needs the operator the section is absent and the verdict says so. The Attention view likewise renders only the groups that have content, plus a one-line clear state.

### Rectangular Switch

The workflow switch is a 48px by 26px ruled track inside a 48px by 44px hit area, with a moving 18px ink block; state is carried by block position, fill, and `aria-checked`, not by text. Its checked state uses a pale signal wash, vermilion border, and a vermilion block.

### Named Rules

**The Aggregate Truth Rule.** Show only aggregate states the API can prove; do not turn the status strip, verdict, or cards into fictional per-file stages, transfer progress, or readiness claims.

## Do's and Don'ts

### Do:

- Do let the truthful verdict and recent photographs carry the first-view hierarchy.
- Do preserve the health-failure, inbound, attention, then monitoring precedence whenever status is summarized.
- Do keep filenames, dates, paths, counts, and storage figures tabular and visibly attached to their evidence.
- Do pair every status color with plain language, visible focus, semantic state, and polite live feedback where implemented.
- Do keep mobile actions at least 44px and collapse motion to a single imperceptible iteration under reduced-motion preferences.

### Don't:

- Don't describe structural validation as a source-to-destination checksum comparison.
- Don't imply per-file pipeline stages, transfer percentage, quarantine reasons, camera identity, or integration readiness that the API does not expose.
- Don't introduce rounded SaaS cards, pill controls, diffuse shadows, gradients as decoration, or a black camera-body dashboard.
- Don't scatter urgent items across the interface; the needs-attention list and Attention index own exceptions.
- Don't use vermilion on routine copy or inactive surfaces; its rarity is what makes the intake thread legible.
