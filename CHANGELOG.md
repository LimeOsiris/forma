# Changelog

All notable changes to Forma are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- README screenshots generated from the real app (`scripts/screenshots.sh`).
- Contributor guide, issue and pull request templates.

## [1.0.0] - 2026-10-20

### Added
- Radial conversion wheel: opens at the pointer, keyboard and mouse navigation, second ring for more formats, option and confirmation cards, progress in the hub, done card with Open, Edit and Reveal.
- Finder entry points: a Finder Sync extension ("Convert with Forma…"), a Services item ("Open in Forma"), a configurable global shortcut (⌥⌘K) for Finder's selection, and opt-in Shift + right-click via the Accessibility API.
- Conversion engine on Apple frameworks: images (PNG, JPEG, HEIC, AVIF, TIFF, BMP, GIF, SVG, WebP input), PDF (to images or text with OCR, split, merge), documents (Markdown, Word, ODT, RTF, HTML, text) and audio (M4A, WAV, AIFF, CAF, FLAC).
- Optional LibreOffice, FFmpeg and cwebp support, detected automatically.
- Image, PDF and text/Markdown editors with undo/redo and safe saving.
- Batch conversion and combining files into one PDF.
- Menu bar item, settings, onboarding, smart wheel ordering and local history.
- 67 unit/round-trip tests and a 44-check in-app UI test harness.
