# FTP Camera Dropbox

<!-- impeccable:product-schema 1 -->
<!-- Primary-user details below are inferred from repository behavior and documentation for the 2026-08-22 redesign. -->

## Platform

web

## Users

The primary user is a technically comfortable photographer or small studio operator running the system on trusted home or studio hardware. They check it during or after a shoot, often from a phone or tablet, to confirm that irreplaceable files arrived intact and to see whether anything needs intervention. They use a larger screen less frequently to browse the library, resolve adapted-lens metadata, and configure automations.

Small production teams may also use the optional Frame.io Camera-to-Cloud intake alongside direct camera FTP uploads.

## Product Purpose

FTP Camera Dropbox receives files from cameras over their native Wi-Fi FTP support, waits for uploads to settle, validates supported media for structural corruption, preserves colliding names without overwriting, and organizes accepted files into capture-date and media-type folders on hardware the user controls.

Success means the operator can answer five questions quickly: Is the intake pipeline healthy? Is anything arriving now? Did the files pass validation? Where were they filed? Does anything require a decision or retry?

## Positioning

It is a local, camera-native ingest dock rather than a cloud gallery or vendor transfer app: a camera can send directly to the user's own Docker host, and the same pipeline validates and organizes both FTP and optional Frame.io intake without making the panel itself a dependency.

## Operating Context

- The panel runs as an optional Docker service on a trusted LAN, commonly beside a NAS or Unraid host.
- Cameras from Fujifilm, Sony, Nikon, and similar systems connect over FTP; SFTP/FTPS is intentionally not the supported camera path.
- Users may be checking a live transfer from a phone, confirming a completed shoot from a tablet, or configuring adapted-lens metadata on desktop.
- Files move through `incoming/`, structural validation, and then either `sorted/YYYY-MM-DD/{raw,jpg,heif,video}/` or `quarantine/`.
- The filesystem is the source of truth. The sorter continues with built-in behavior when the panel is unavailable.

## Capabilities and Constraints

- Show aggregate intake health, files waiting in `incoming/`, active FTP transfers, available storage, recent accepted files, files dated today, render-queue depth, pending lens decisions, and quarantine contents.
- Browse the sorted library by capture date and media type.
- Enable or disable existing workflow features without restarting the sorter.
- Create, edit, test, and delete adapted-lens metadata rules; resolve unknown-lens questions without changing exposure data.
- Add or remove watched folders under `/data` and retry or stage quarantined files for later deletion.
- Structural validation is not a camera-to-destination checksum comparison and must not be described as one.
- Existing APIs expose aggregate counts, not per-file processing stages, transfer progress, quarantine failure reasons, or integration-readiness details. The interface must not invent those states.
- `sorted_today` currently counts files stored in today's capture-date folder, not files processed during the current day.
- Authentication is deliberately outside the panel; deployment assumes a trusted LAN and can use a Host allowlist for DNS-rebinding defense.

## Brand Commitments

- Product name: FTP Camera Dropbox; the compact panel wordmark may use “Camera Dropbox.”
- Voice: plain, calm, technically honest, and specific. Reassure with evidence rather than celebratory language or cloud-product promises.
- Photography may supply familiar terminology, but task labels must remain immediately understandable.

## Evidence on Hand

- [README.md](README.md) documents setup, the camera-to-library pipeline, supported behavior, and hard-earned operational failure modes.
- [panel/app.py](panel/app.py) is the authoritative API and validation contract for the control panel.
- [panel/index.html](panel/index.html) contains the current complete frontend and every existing interaction that the redesign must preserve.
- The repository contains no testimonials, customer logos, commercial benchmarks, pricing, or real photography licensed for marketing use; future work must not fabricate them.

## Product Principles

1. Lead with confidence: show whether files are moving safely and whether action is required before exposing configuration.
2. Be exact about evidence: distinguish healthy, derived, unavailable, enabled, and ready states; never overclaim verification.
3. Preserve every original: quarantine and collision handling should feel recoverable, never destructive or mysterious.
4. Keep routine checks fast: a five-second phone glance should answer the primary questions.
5. Put advanced controls behind the jobs they serve, while keeping the system understandable without Docker or EXIF expertise.

## Accessibility & Inclusion

The web panel must support keyboard navigation, visible focus, meaningful text alternatives, non-color status cues, 44px touch targets on compact screens, reduced motion, and readable contrast. Live status and save/error feedback must be announced to assistive technology.
