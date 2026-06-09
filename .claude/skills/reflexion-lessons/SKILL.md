---
name: reflexion-lessons
description: Append-only episodic-memory writer. The ONLY path the agent process can write to LESSONS.md via OS append-only ACL. Used by archivist subagent at end of each task to distill 1-3 non-obvious lessons.
version: 0.1.0
---

# Reflexion Lessons

Episodic memory accumulator. LESSONS.md is permissioned at the OS level: the agent's user account has `AppendData + ReadData` allow rules and `WriteData + Delete` deny rules. This skill is the only path that satisfies the OS constraints.

## Inputs

- `Title:` one-line lesson title
- `Context:` task-id / generation / agent
- `Lesson:` single-sentence rule
- `Why:` single-sentence reason (cite past incident if applicable)
- `How-To-Apply:` single-sentence trigger condition
- `Source:` `archive/gen-NNNN/agent-MMMM` (or `workspace/<task>/...` if pre-promotion)

## Workflow

1. Read the last 5 lessons in LESSONS.md to avoid duplicate filing
2. If the new lesson semantically duplicates one of the last 5 (cosine ≥ 0.85 on full body) → **don't write.** Surface the duplicate to the archivist instead.
3. Render the lesson in the canonical schema (below).
4. **Append using a handle opened with `FileSystemRights.AppendData` ONLY** — `Add-Content`, `[IO.File]::AppendAllText`, `Out-File -Append`, `>> file` all request `FILE_GENERIC_WRITE` which expands to include `WriteData`. The OS DENY-WriteData rule blocks them even though `AppendData` is allowed (DENY wins over ALLOW). You MUST use the granular FileStream constructor that asks for `AppendData` rights specifically. Use the bundled helper:

   **Helper (preferred):** call `.claude/skills/reflexion-lessons/append.ps1`
   ```bash
   powershell -ExecutionPolicy Bypass -NoProfile -File .claude/skills/reflexion-lessons/append.ps1 -EntryFile workspace/<task>/lesson.md
   ```
   The helper opens LESSONS.md via:
   ```powershell
   New-Object FileStream($path,
       [IO.FileMode]::Append,
       [Security.AccessControl.FileSystemRights]::AppendData,
       [IO.FileShare]::Write, 4096, [IO.FileOptions]::None)
   ```

   **Python equivalent:**
   ```python
   import ctypes
   # CreateFileW with FILE_APPEND_DATA (0x0004) only - not GENERIC_WRITE
   kernel32 = ctypes.windll.kernel32
   handle = kernel32.CreateFileW('LESSONS.md', 0x0004, 0x0002, None, 4, 0x80, None)
   # ... WriteFile, CloseHandle
   ```
   (Or just call the PowerShell helper above from python via subprocess — simpler.)

5. **Do NOT use** Claude's Edit/Write tools, `Add-Content`, `AppendAllText`, or `>>` redirect — all blocked by OS-level DENY. The bundled `append.ps1` helper is the only validated path.

6. **Workflow:**
   ```bash
   # 1. Render lesson into a temp file in workspace/
   cat > workspace/$TASK/lesson.md <<EOF
   <canonical-schema-block>
   EOF
   # 2. Hand to append helper
   powershell -File .claude/skills/reflexion-lessons/append.ps1 -EntryFile workspace/$TASK/lesson.md
   ```

## Canonical schema

```
## [YYYY-MM-DD] <Title>

**Context:** <task / generation / agent>
**Lesson:** <single sentence: the rule>
**Why:** <single sentence: the reason>
**How to apply:** <single sentence: when this kicks in>
**Source:** <archive tag or workspace path>

---
```

The trailing `---` is the canonical separator. Always include.

## Rules

- **Append only.** OS-enforced; trying to edit will fail with EACCES.
- **No editorializing.** State the lesson as a rule, not a story. "Always X" / "Never Y" / "When A, do B."
- **Cite lineage.** Every lesson must reference an archive tag (or workspace path for pre-promotion lessons). Untraceable lessons are noise.
- **Failures count.** "Disproven hypothesis: X did NOT help" is as valuable as "Confirmed: Y helped."
- **No PII, no secrets.** LESSONS.md is committed to git.
- **Brevity gate:** if total lesson body exceeds 300 words, reject and ask archivist to split into multiple lessons.

## Why this schema

Reflexion (Shinn et al., 2023) showed that compact episodic memory entries with explicit *Why* + *How-to-apply* fields outperform unstructured rumination by ~20% on multi-step tasks. The schema here is the minimal version that preserves that gain.
