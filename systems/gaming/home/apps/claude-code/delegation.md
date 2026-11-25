
# Delegation

Search results, test runs and logs fill the context quickly, and most of that
output matters only for the conclusion it supports. Before running something
noisy, ask whether you will need its output again or only the conclusion. If
only the conclusion, give it to a subagent: only its final report returns to
this session, which keeps the context on the work itself and defers
compaction. Do this without being asked.

Choose the agent for the task rather than defaulting to `general-purpose`:

| Task | Agent |
| --- | --- |
| Finding code, config or usages across more than a few files | `Explore` |
| Designing the approach to a non-trivial change | `Plan` |
| A decided, mechanical change, especially one spanning many files | `implementer` |
| Builds, tests, `nix flake check`, linters | `verifier` |
| Logs and read-only live state: journal, kubectl, Loki, Prometheus | `log-reader` |
| A whole investigation, handed off with its root cause and fix returned | `debugger` |
| Breakglass for an investigation that has stopped converging | `problem-finder` |

Use `general-purpose` only when a task fits none of these. Ask `Explore` for
paths, line numbers and a one-line summary of each match.

Read files directly in the main session when you are about to edit them, and
keep lookups whose target you already know, which take a call or two, in the
main session as well. Delegation pays for itself only when it keeps
substantial output out of the context.

A subagent knows only its brief. State the goal, what you have already ruled
out and the files or hosts involved, and ask for a short report with findings
first and no narration. Run independent subagents in parallel. Version
control, deployments, leases and changes to live systems stay in the main
session.

## Codex

Codex runs on the operator's ChatGPT plan, so work handed to it spends no
Claude usage. Prefer it to `implementer` for a decided change and for a
self-contained investigation or second-opinion review whose result is a diff
or a short report. Codex has the same NetBox, Grafana, UniFi and Home
Assistant MCP servers, but changes through them stay in the main session.

Call `codex exec` directly from the main session rather than through the
`codex:codex-rescue` agent, which spends a Sonnet turn forwarding the prompt
and cannot request `max` effort. Stdout carries only Codex's final message:

```sh
codex exec -C <repo> -s workspace-write -m gpt-6.2-sol \
  -c model_reasoning_effort=medium "<brief>" 2>/dev/null
```

Use `-s read-only` for review and diagnosis, and `run_in_background` for
anything likely to run past a few minutes. Codex reads each repository's
`AGENTS.md`, so the brief covers the task, not the house rules. It edits only
the working copy; review its diff, then commit, deploy, lease and verify from
the main session as for any subagent.

| Model | Use for | Effort |
| --- | --- | --- |
| `gpt-6.2-sol` | Default: implementation, refactors, tests, Nix and config edits | `low` mechanical, `medium` usual, `high` multi-file or subtle |
| `gpt-6.2-astra` | Hard debugging, design-sensitive changes, adversarial review | `high`; `xhigh` or `max` when a cheaper pass failed |
| `gpt-6.1-terra` | Screenshots, images, UI and browser work; very large reads | `low` or `medium` |

Sol and Terra default to a 500k context window. When a run on either must hold
more, such as a large codebase read or a long log, add
`-c model_context_window=872000`, their current ceiling. Leave it off
otherwise: a long session resends its whole context each turn and compacts
later, which spends quota faster. Never override Astra's 272k window; give it
a narrow brief, and hand work that needs more context to Sol or Terra. Avoid `ultra`, which delegates to Codex's own subagents and
multiplies usage without the main session seeing the work.

The plugin's `/codex:review` and `/codex:adversarial-review` remain useful
when the operator asks for a Codex review of the current diff.

## Debugging

Whoever debugs owns the hypotheses and the fix, and subagents gather
evidence for it. Brief them with a question that could falsify the current
hypothesis rather than one that invites confirmation, and ask them to list
anything else anomalous they saw, one line each. Read the decisive evidence
yourself, and keep tight reproduce-and-fix loops in your own context.

Debug in the main session when the problem is close to the work in hand.
Hand the whole investigation to `debugger` when it is broad or long enough
to crowd out that work, and say whether it should also fix the problem. Its
report separates observation from inference; check that its root cause
explains every symptom before acting on it. Any fix it makes is left in the
working copy, so commit, deploy and verify it on the live system from the
main session.

Call `problem-finder` when an investigation stops converging: two fixes that
did not resolve the symptom, three falsified hypotheses, contradictory
evidence, behavior believed impossible, or rechecking what has already been
checked. `debugger` follows the same rule. Brief it with the symptom, the raw
observations and what was tried, but not the current theory, then reassess
the model against its report. It runs at maximum effort, so use it only at
these points or when the operator asks for breakglass.
