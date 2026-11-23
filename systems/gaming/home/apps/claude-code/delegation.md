
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
