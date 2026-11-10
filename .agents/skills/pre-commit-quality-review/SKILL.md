---
name: pre-commit-quality-review
description: Use when preparing a Flux6 commit, amend or squash, or when the user requests a pre-commit structural quality review.
license: GPL-3.0; see ../../LICENSE and ../../UPSTREAM.md
---

# Pre-commit quality review

Check whether the intended change has a coherent final structure. Read [AGENTS.md](../../../AGENTS.md) and the
affected platform instructions. This skill grants no additional authority to commit, push or rewrite history.

## Triage and snapshot

Start with status, the intended diff and only the local context it needs. Formatting, generated output, copy edits,
mechanical moves and simple local fixes ordinarily skip structural review; say it was skipped, not that it passed.
Review when ownership, dependency direction or public abstractions change, a core implementation is replaced, or
successive patches introduce duplicate paths or indirection. An explicit structural-review request bypasses triage.

| Operation | Comparison baseline |
| --- | --- |
| Regular commit | `HEAD` |
| Amend | Parent of the commit being replaced |
| Squash | Version immediately before the agreed range |
| Initial commit | Empty tree |

Resolve a materially ambiguous range or merge parent before reviewing it. For partially staged files, inspect the
staged version; an unstaged fix is not part of the pending commit. Preserve unrelated edits, staging and other worktrees.

## Review the changed responsibilities

Read the complete affected units and compare their before/after behavior and call relationships. Follow dependencies
only as far as a concrete concern requires. Check:

- Whether independent responsibilities are mixed or UI/platform code now owns state that belongs elsewhere.
- Whether new forwarding layers, cycles or abstractions add coupling without isolating a real responsibility.
- Whether repeated branches, fallbacks or boolean combinations obscure ownership and cleanup.
- Whether the change duplicates an existing capability or introduces multiple sources of lifecycle truth.
- Whether the change leaves obsolete paths, unused parameters, stale comments or invalid test boundaries behind.

Report introduced or worsened issues with a concrete maintenance cost and a small proposal compatible with the
project. Naming taste, line count, missing fashionable patterns and untouched historical debt are not findings.
Do not couple platform implementations merely to remove a few similar lines. A structural review does not replace
functional, security, compatibility or performance checks; report incidentally found serious defects distinctly.

## Findings and completion

For a qualifying finding, give the file/symbol/location, evidence from the change, its concrete cost and the smallest
resolution with any behavior or scope impact. Complete independent read-only review and checks first. Resolve
in-scope issues already covered by the user's authorization; ask only when the proposed fix exceeds it or a material
tradeoff needs a decision. Do not introduce an extra confirmation merely because a review occurred. Preserve an
already accepted tradeoff unless relevant new code invalidates it.

With no qualifying finding, give a short scope and conclusion, then continue the authorized workflow. After a fix,
verify its effects rather than restarting a repository-wide improvement search.

Before an authorized commit, inspect status and the actual staged diff again. Run the checks for the changed areas
from the [development guide](../../../docs/development/README.md), reuse valid results and repeat invalidated checks.
For documentation-only edits, use link/repository/skill checks; Flutter, shared Go and native code use their affected
platform checks. Do not claim that the removed upstream editor/pre-commit hook configuration is installed in Flux6.

Use Conventional Commits without agent co-author trailers. Keep mechanical maintenance, removals and behavior changes
separate when committing them. Report the reviewed scope, resolved issues or accepted tradeoffs, checks and limits.
Only report a commit as created after it actually exists; do not push or publish as a side effect of review.
