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
  link: "#1748c7"
  healthy: "#08744f"
  warning: "#9b4a00"
  danger: "#a61f13"
  focus: "#1748c7"
typography:
  display:
    fontFamily: '"Big Shoulders", "Arial Narrow", sans-serif'
    fontSize: "clamp(50px, 7vw, 92px)"
    fontWeight: 800
    lineHeight: 0.88
    letterSpacing: "-0.025em"
  headline:
    fontFamily: '"Big Shoulders", "Arial Narrow", sans-serif'
    fontSize: "clamp(24px, 3vw, 36px)"
    fontWeight: 750
    lineHeight: 1
    letterSpacing: "-0.01em"
  title:
    fontFamily: '"Big Shoulders", "Arial Narrow", sans-serif'
    fontSize: "30px"
    fontWeight: 800
    lineHeight: 1
    letterSpacing: "normal"
  nav:
    fontFamily: '"Big Shoulders", "Arial Narrow", sans-serif'
    fontSize: "clamp(18px, 1.7vw, 23px)"
    fontWeight: 750
    lineHeight: 1
    letterSpacing: "0.01em"
  control:
    fontFamily: '"Big Shoulders", "Arial Narrow", sans-serif'
    fontSize: "14px"
    fontWeight: 750
    lineHeight: 1
    letterSpacing: "0.025em"
  body:
    fontFamily: 'ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.48
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
    padding: "0 18px"
    height: "112px"
  nav-tab-active:
    backgroundColor: "{colors.signal}"
    textColor: "#ffffff"
    typography: "{typography.nav}"
    rounded: "{rounded.square}"
    padding: "0 18px"
    height: "112px"
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.sheet}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "11px 16px"
  button-primary-hover:
    backgroundColor: "{colors.signal}"
    textColor: "{colors.sheet}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "11px 16px"
  button-secondary:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "11px 16px"
  button-danger:
    backgroundColor: "transparent"
    textColor: "{colors.danger}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "11px 16px"
  button-quiet:
    backgroundColor: "transparent"
    textColor: "{colors.link}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "8px 10px"
  field:
    backgroundColor: "{colors.sheet}"
    textColor: "{colors.ink}"
    typography: "{typography.metadata}"
    rounded: "{rounded.control}"
    padding: "10px 12px"
    height: "44px"
  chip:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.square}"
    padding: "6px 8px"
  switch-off:
    backgroundColor: "{colors.sheet-2}"
    textColor: "{colors.ink-soft}"
    typography: "{typography.label}"
    rounded: "{rounded.square}"
    width: "76px"
    height: "38px"
  switch-on:
    backgroundColor: "#f4d3cc"
    textColor: "{colors.signal-dark}"
    typography: "{typography.label}"
    rounded: "{rounded.square}"
    width: "76px"
    height: "38px"
  proof-card:
    backgroundColor: "{colors.sheet}"
    textColor: "{colors.ink}"
    typography: "{typography.metadata}"
    rounded: "{rounded.square}"
  intake-rail:
    backgroundColor: "{colors.sheet}"
    textColor: "{colors.ink}"
    typography: "{typography.metadata}"
    rounded: "{rounded.square}"
    padding: "18px clamp(24px, 3.2vw, 46px) 20px"
  condition-report:
    backgroundColor: "#f1d8d1"
    textColor: "#54251f"
    typography: "{typography.body}"
    rounded: "{rounded.square}"
    padding: "0 22px 30px"
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
- Four equal index tabs and a mobile bottom index.
- One vermilion intake thread, active only when work is arriving.
- Aggregate status and condition-report evidence without invented per-file progress.

## Colors

The palette is a cool, low-chroma paper-and-ink field interrupted by functional vermilion, evidence blue, monitoring green, and warning amber. The frontmatter values are normative; the implementation keeps separate semantic aliases where two roles currently share one value.

### Primary

- **Intake Vermilion** (`signal`): Marks the active index tab, live-arrival verdict, intake thread, active nodes, and condition-report heading.
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

- **Display** (800, `clamp(50px, 7vw, 92px)`, 0.88): Page verdicts and primary page titles; keep the measure to roughly 13 characters and use the mobile override `clamp(48px, 15vw, 72px)` below 760px.
- **Headline** (750, `clamp(24px, 3vw, 36px)`, 1): Uppercase section headings and ledger divisions.
- **Title** (800, 30px, 1): Condition-report and grouped-task headings.
- **Body** (400, 15px, 1.48): Explanations and operational guidance; larger verdict support copy may rise to `clamp(16px, 1.7vw, 21px)`.
- **Label** (700, 10px, 0.08em): Uppercase evidence labels, counters, and field labels.
- **Metadata** (700, 13px, 1.3): Filenames, paths, counts, dates, and compact technical facts, with tabular numerals wherever values align.

### Named Rules

**The Register Voice Rule.** Use Big Shoulders for hierarchy, system sans for explanation, and monospace only where the content behaves like a record.

## Layout

The shell is a centered ledger no wider than 1440px, framed by one-pixel rules. Desktop navigation is a four-cell horizontal index joined to the brand and status strip. Major compositions use hard grid joins: the verdict pairs one oversized sentence with two evidence cells; the Now view pairs a narrow condition report with a broad proof field; recent proof uses four columns at full width.

Gutters are fluid rather than a named spacing scale: header padding uses `clamp(20px, 2.7vw, 40px)`, page and content gutters use `clamp(20px, 4vw, 56px)`, and major vertical section padding typically falls between 28px and 48px. Preserve the dense register rhythm instead of inserting isolated floating cards.

At 1099px the header compacts, the verdict stacks, proof becomes two columns, and the attention column narrows to 240px. At 760px the four index tabs move into a fixed 68px bottom bar, major grids become single-column, galleries stay two-column, and controls expand to at least 44px. At 440px evidence facts and action rows stack while the two-column contact sheet remains.

### Named Rules

**The Four-Tab Rule.** Now, Library, Attention, and Automations always share the navigation width equally; on small screens the same index moves intact to the bottom edge.

## Elevation & Depth

This is a flat system with no surface elevation or card shadow vocabulary. Depth comes from the difference between paper, sheet, and muted-sheet tones; a 512px archival-paper texture under translucent paper washes; one-pixel structural rules; and the overlap created by clipped tabs and registers. The intake-stage circles use `0 0 0 1px` only as an outline extension, not as elevation.

### Named Rules

**The Flat Ruled Rule.** Separate surfaces with paper tone, line weight, and shared edges; never lift routine panels with shadows.

## Shapes

Square is the default silhouette. Buttons and fields permit only a restrained 2px radius; the rectangular switch is explicitly square. True circles are reserved for the status dot, camera mark, and intake-stage nodes.

Clipping supplies the signature geometry: the active desktop index loses a 14px top-right corner, reduced to 10px on mobile, while the condition report loses an 18px top-right corner. Structural borders are one pixel and the intake connector is two pixels; thumbnails and ledger cells stay square.

### Named Rules

**The Clipped Accession Rule.** Use one deliberate top-right cut to mark selection or exception; do not substitute rounded cards, pill controls, or ornamental corner systems.

## Components

### Buttons

- **Shape:** Registry rectangle with a 1px ink border and a restrained 2px radius; 42px minimum height on desktop and 44px on mobile.
- **Primary:** Near-black ink fill with accession-sheet text and `11px 16px` padding; hover switches to vermilion and active presses down by 1px.
- **Secondary:** Transparent sheet with register-ink text; hover fills with the muted sheet.
- **Danger:** Transparent danger border and text; hover fills danger red and reverses the label to white.
- **Quiet:** Borderless evidence-blue action; hover gains a muted-sheet field and dark ink. Mobile quiet actions still present a 44px target.
- **Focus / Disabled:** The global focus treatment is a 3px evidence-blue outline with 3px offset. Disabled controls retain their form at 48% opacity and use a waiting cursor.

### Chips

- **Style:** Square, one-pixel register border, compact monospace label, and `6px 8px` desktop padding.
- **State:** Removal is a separate danger-colored button; on mobile that button becomes a 44px square target while the text half remains compact.

### Cards / Containers

- **Corner Style:** Square by default; proof thumbnails and captions share hard edges.
- **Background:** Accession sheet over a muted-sheet media placeholder.
- **Shadow Strategy:** None; cards join through one-pixel dark rules.
- **Internal Padding:** Proof captions use `14px 14px 16px`, compacting to 11px on mobile.
- **Behavior:** Proof media stays 4:3. Hover scales imagery only to 1.018 and adds a slight contrast lift; filenames, media type, time, and capture-date destination remain visible evidence.

### Inputs / Fields

- **Style:** Accession-sheet fill, one-pixel dark register border, 2px radius, monospace value, `10px 12px` padding, and a 44px minimum height.
- **Focus:** Border changes to evidence blue and gains a 3px translucent blue outline.
- **Placeholder:** Faint ink at full opacity. Labels remain uppercase 10px monospace.

### Navigation

Four equal uppercase Big Shoulders tabs form one ruled index. Hover uses the muted sheet; the active tab uses vermilion, white text, `aria-current="page"`, and the clipped top-right corner. Attention may carry a small bordered monospace count. Below 760px, the same four tabs become a fixed 68px bottom index while the compact header retains brand and aggregate status.

### Aggregate Status and Verdict

The chrome computes inbound work as receiving plus files waiting or checking. Attention is active quarantine plus pending lens decisions, with one additional item when health has failed. Failed health takes precedence, then inbound work, then unresolved attention, then the clean monitoring state. The oversized verdict follows the same order and pairs the sentence with explicit pipeline evidence and storage availability. Status always includes text and a polite spoken label; color is never the only cue.

### Intake Rail

The rail has four fixed stations: Camera, Receiving, Waiting / Checking, and Filed by Date. Its two-pixel connector turns vermilion and reveals across the row only while aggregate inbound work is nonzero; it never represents per-file progress. On mobile, station names and values remain while secondary descriptions drop away.

### Condition Report

One 18px-clipped blush register holds every urgent category: failed pipeline health, recoverable quarantine files, and optional lens decisions. A vermilion heading and ruled issue entries carry consequence copy and direct actions. When clear, it states that nothing needs the operator; on mobile the clear report may collapse so accepted photographs reach the first scroll.

### Rectangular Switch

The workflow switch is a 76px by 38px ruled rectangle with explicit ON/OFF text and a moving 28px ink block. Its checked state uses a pale signal wash, vermilion border, darker signal text, and a vermilion block. On mobile the control becomes 44px high and the block becomes 34px, preserving a full touch target.

### Named Rules

**The Aggregate Truth Rule.** Show only aggregate states the API can prove; do not turn the intake rail, verdict, or cards into fictional per-file stages, transfer progress, or readiness claims.

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
- Don't scatter urgent items across the interface; the condition report and Attention index own exceptions.
- Don't use vermilion on routine copy or inactive surfaces; its rarity is what makes the intake thread legible.
