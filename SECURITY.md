# Security

Forma processes files locally and never makes network requests. Even so, it parses untrusted files and, if you opt in, uses an event tap and the Accessibility API, so security reports matter.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Use GitHub's private reporting: **Security › Report a vulnerability** on this repository. Include steps to reproduce and, if possible, a minimal sample file.

You'll get an acknowledgement within a few days. Fixes are released as soon as practical.

## Scope

In scope:
- Crashes or code execution from malformed input files.
- Path traversal, overwriting files, or writing outside the chosen destination.
- Misuse of the `forma://` URL scheme, the event tap, or Apple Events.
