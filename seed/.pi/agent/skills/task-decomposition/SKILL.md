---
name: "task-decomposition"
description: "Break down any non-trivial problem into parallel/sequential subtasks and execute each in a subagent with the minimum model capable of completing it. Use when a problem has 3+ steps, multiple concerns, or parallelizable workstreams."
version: 1
created: "2026-06-12"
updated: "2026-09-23"
---

## Model Tiers

| Tier | Model / effort | Use for |
|------|----------------|---------|
| Fast | `"rits/zai-org/glm-5-3"` / `high` | Reads, search, commands, collecting info, simple/mechanical edits |
| Standard | `"rits/zai-org/glm-5-3"` / `max` | Implementation and tests |
| Full | `"gpt-6.1-sol"` / `xhigh` | Complex analysis, architecture, strategy, complex debugging, cross-file judgment, final synthesis |

Use Fast tier for quick tasks, Standard tier for implementation and tests, and Full tier for complex analysis or strategy.

## Procedure

**0. Plan** —  The agent explores, may ask clarifying questions, then produces a `<proposed_plan>` block. Refine with "Stay in Plan mode"; when satisfied choose "Implement this plan" then **immediately abort the triggered turn**. Use the plan's Key Changes as input to step 1.

**1. Decompose** — For each change: can it run in parallel? What does it depend on? What tier?

**2. TaskCreate** — One task per subtask. The description must be **fully self-contained** (subagents have no conversation history): full file paths, exact deliverable. Use unpinned `"general-purpose"` for tier-controlled tasks, including exploration. For exploration, explicitly require read-only work: no file creation, edits, deletion, or state-changing commands. This is a prompt restriction, not a restricted tool set. Use a specialist only when its role and allowed tools fit and its configured model/thinking match the required tier. Do not invent agent types.

**3. Wire deps** — `TaskUpdate { addBlockedBy: [...] }` on every task that has a prerequisite.

**4. Execute by tier** — `TaskExecute` selects model but has no effort parameter. Its agents need matching configured thinking defaults; when exact effort matters, use `Agent` with explicit `thinking` and update task status yourself:
```
Agent [read task]         model="rits/zai-org/glm-5-3" thinking="high"
Agent [implement task]    model="rits/zai-org/glm-5-3" thinking="max"
Agent [complex synthesis] model="gpt-6.1-sol" thinking="xhigh"
```

**5. Verify** — Read the actual changed files; never trust agent summaries. Synthesize only after confirming.

## Example

`/plan Add input validation to endpoints A, B, C and write tests`

| # | Task | agentType | Tier | Blocked by |
|---|------|-----------|------|------------|
| 1 | Read A, B, C — document input handling; read-only, no state changes | general-purpose | Fast| — |
| 2 | Add validation: endpoint A | general-purpose | Standard| 1 |
| 3 | Add validation: endpoint B | general-purpose | Standard| 1 |
| 4 | Add validation: endpoint C | general-purpose | Standard| 1 |
| 5 | Write tests for A, B, C | tester | Standard| 2, 3, 4 |


## Pitfalls

- **Pinned model/thinking** — agent configuration outranks call-level parameters. Built-in `Explore` pins Haiku; use unpinned `general-purpose` with explicit tier model/thinking instead.
- **Non-self-contained prompts** — missing file paths or referencing "the above" causes silent wrong results; this is the most common failure.
- **Over-splitting** — tasks that must share state or coordinate tightly belong in one task.
- **Trusting summaries** — agents report intent; read the actual files.
- **Missing deps** — parallel tasks that need each other's output will race.
