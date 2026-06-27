# Critique: strict-concurrency-flag-flip-2026-06-27.md

**Scope** — One-page review of the Step-5 plan for Issue #19 (final Swift 6 migration polish).

## 1. Under-specified seams (file:line)

- `Package.swift:24-29` — `ReliaBLEMock` target literal already contains `exclude:`. Plan does not state where `swiftSettings:` must be inserted relative to `exclude:`. Implementer could produce invalid Swift syntax.
- `Documentation.docc/Documentation.md` — plan references the existing `### Concurrency` topic group but gives no line number or exact insertion point for `<doc:Concurrency>`. Placement could break list structure if the group is currently a single bullet.
- `swift package generate-documentation` gate — no mention of required `--target ReliaBLE` flag (DocC catalog lives only in the production target).

## 2. Contradictions / missing dependencies

None. Plan correctly notes that `swift-tools-version:6.1` already implies Swift 6 + complete concurrency, Willow `LogWriter:Sendable` is accurate, and the two `Task.detached` smoke tests already exist.

## 3. Over-planning risk (cut or simplify)

- “Background (verified current state)” section is ~40 lines of repetition; an implementer will observe the clean build themselves. Reduce to 2–3 bullets.
- “Open Questions” and “Diagram format” bullets add no actionable decisions for a 4-edit task — delete.
- Deliverable #3 (`OSLogWriter` comment) is cosmetic only; plan itself says “apply `@unchecked` only if build fails.” Consider dropping the item.

## 4. Questions that change order/correctness

- Must `swift package generate-documentation` succeed with zero warnings, or is the gate only that the new article renders? (Affects whether the step must actually invoke the plugin.)
- Does `Concurrency.md` require an explicit entry in the DocC catalog index, or does the `<doc:>` link in `Documentation.md` suffice? Answer determines if a second DocC edit is needed.

**Recommendation** — Trim verbosity and the two open-question items; add one clarifying sentence on `swiftSettings` placement and the exact insertion point in `Documentation.md`. The plan is otherwise minimal and correct.