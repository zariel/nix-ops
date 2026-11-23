
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
