---
name: "markdown-format"
description: "Check or fix markdown formatting and the 120-char line-wrap rule with prettier. Use after editing .md files, before committing docs, when markdown lines exceed 120 chars, or when asked to \"fix markdown formatting\" / \"check line lengths\"."
version: 1
created: "2026-10-27"
updated: "2026-10-27"
---
## When to Use
Any markdown the agent or user edited must obey the global 120-char wrap convention; also when a docs change needs a formatting gate before commit. Skip for files whose layout is generated or hand-mandated (e.g., fixtures asserting exact bytes).

## Procedure
1. Fix in place: `npx --yes prettier --write --print-width 120 --prose-wrap always <files-or-globs...>`. The flags are the config; no config file needed. Fenced code blocks are left untouched.
2. Check-only gate (pre-commit, CI): same command with `--check` instead of `--write`; nonzero exit lists offending files.
3. Sweep for residual over-length lines (unbreakable URLs survive rewrap): `awk 'length > 120 {print FILENAME":"FNR}' <files...>`; fix any hit by hand (shorten text or use a reference-style link).
4. Optional structural pass (heading style, blanks, lists): `markdownlint-cli2 --fix "**/*.md"` — on PATH via nvim mason. It fixes rule violations but cannot rewrap long lines.

## Pitfalls
- Prettier normalizes beyond wrapping: list markers (`*` -> `-`), collapsed blank lines, re-padded tables. Review the diff; never run blindly on foreign docs where byte stability matters.
- Unbreakable tokens (long URLs) stay over 120 and `--check` still passes — the awk sweep is the only strict length gate.
- Unusual YAML front-matter can be reformatted; simple front-matter is preserved (verified).
- `npx` pulls the latest prettier (3.9.x); pin a devDependency when diff stability across time matters.
- markdownlint-cli2 cannot rewrap lines (MD013 is not fixable) — never present it as the wrap fixer.

## Verification
1. `npx --yes prettier --check --print-width 120 --prose-wrap always <files>` exits 0.
2. The awk sweep from step 3 prints nothing (or only hand-accepted URL lines).