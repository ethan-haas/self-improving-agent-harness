# AgentA — Self-Improving Multi-Agent Engineering Harness

AgentA is an autonomous software-improvement system: it proposes changes to a target
codebase, **verifies them through a 7-tier gauntlet**, and keeps only what *provably* improves
a metric — so progress is earned, not hallucinated. It pairs a Karpathy-style autonomous
research loop with several meta-improvement strategies and a panel of specialized agents, all
running sandboxed.

> **Attribution.** The autonomous *inner research loop* is ported from Udit Goenka's
> `autoresearch` (MIT — itself based on Andrej Karpathy's autoresearch). The
> **meta-improvement architecture, multi-agent orchestration, and 7-tier verification stack in
> this repository are my own work.**

## How it works
1. **Inner loop (autoresearch):** propose a change → run it → measure against a fixed metric →
   keep or discard.
2. **Meta-improvement loops** wrap the inner loop:
   - **Self-modifying scaffolds** (DGM-style) — the system edits its own harness; edits are
     *staged* and promoted only after passing verification.
   - **Prompt evolution** (GEPA-style) — agent prompts are mutated and selected on results.
   - **Skill discovery** (Voyager-style) — successful tool-compositions are archived as reusable
     skills.
   - **Episodic memory** (Reflexion-style) — an append-only lessons log carries learning across
     runs.
3. **Agent panel:** specialized roles — planner, coder, tester, reviewer, critic, researcher,
   archivist, meta-improver — with model routing (heavier models for hard steps, lighter ones
   for cheap steps).

## Why the output is trustworthy — the 7-tier verification stack
Every candidate change must survive, in order:

`parse → unit → property → mutation → benchmark → sealed holdout → fresh-context critic`

The **sealed holdout** is isolated from the agent (it can't read or edit it), so a change can't
be gamed into looking good — it has to generalize. Anything that fails a tier is discarded.

## Safety / isolation
- Runs sandboxed; the harness directory and the holdout are protected (read-only / deny-listed
  to the agent).
- The lessons log is append-only.
- Self-modifications are staged and promoted by the host only after verification passes.

## Stack
Python · PowerShell · Claude Code · multi-agent orchestration · sandboxed execution (Windows).

## Status
Working — runs multi-day autonomous experiments across algorithmic and software tasks.

---
*No secrets are committed; environment files are gitignored. This README describes the
architecture; operational/host scripts are environment-specific.*
