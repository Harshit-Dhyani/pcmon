# AGENTS.md

Short, strict rules for the `pcmon` workspace. Optimize for correctness, security, production readiness, maintainability, and real diagnostic value.

## 0. Operating Default

* For any non-trivial task, start with a short plan before editing.
* Prefer discovery, verification, then implementation.
* If implementation reveals the plan is wrong, stop, update the plan, and continue from the corrected plan.
* Keep changes small, checkable, and reversible.
* Do not claim completion without evidence.

## 1. Core Standard

* Ship code that is safe, testable, and production-grade.
* Preserve working behavior unless the task explicitly changes behavior.
* Prefer one source of truth per concern.
* Prefer minimal, verifiable diffs over broad rewrites.
* Fix root causes, not symptoms.
* Do not leave the repo in a half-migrated state.

## 2. Product Identity

* The official product name is `pcmon`.
* The GitHub repository name is `pcmon`.
* The CLI command name is `pcmon`.
* Do not introduce alternate product names, placeholder branding, or inconsistent naming in docs, code, UI, package metadata, or command examples.

## 3. Product Scope

`pcmon` is a local-first Windows system monitoring and diagnostics tool.

It may include:

* PowerShell-based data collection
* local HTTP server and local API
* HTML/CSS/JS dashboard
* process inspection and control
* memory, commit, paging, disk, CPU, GPU diagnostics
* snapshot, compare, export flows
* future CLI packaging for bun, npm, pnpm
* future lightweight desktop shell if explicitly added

`pcmon` is not a generic web app. Do not apply random website conventions when they do not improve a local diagnostics tool.

## 4. Discovery-First Rule

Before implementation work:

* identify the real owning file or files
* inspect stale, duplicate, scratch, or half-migrated monitor files
* inspect actual action flow before editing kill, suspend, resume behavior
* inspect snapshot, compare, export logic before adding new flows
* inspect actual UI structure before adding tabs, cards, controls, or data bindings
* inspect current docs before adding new instructions

Treat file paths and project structure as hints until verified in the current repo.

## 5. Source of Truth Rules

Before changing behavior, find the real owner.

Typical ownership areas:

* monitor and data collection
* process actions
* snapshot, compare, export logic
* HTTP and API handling
* dashboard HTML, CSS, JS
* CLI and bootstrap entrypoints
* docs and README for runtime instructions

Rules:

* Do not change a file in isolation if the same behavior is also owned elsewhere.
* Do not create duplicate implementations of the same metric, action, export path, or UI state.
* Do not create a second monitoring path when the existing one should be improved.
* Resolve data once where practical, then consume the resolved shape.
* Keep one canonical response shape for `/data` and update producers and consumers together.

## 6. Planning and Execution

For non-trivial tasks, write a short plan that includes:

* goal
* source-of-truth owners
* risks
* verification steps
* done-when checklist

Rules:

* If the task is 3 or more steps, has architectural implications, or touches multiple layers, plan first.
* Re-plan immediately when new evidence invalidates the current approach.
* Use planning for verification too, not only for building.
* Track progress clearly during execution.
* Prefer the smallest safe slice now over a speculative rewrite.

## 7. Non-Negotiables

* Never commit, push, or open a PR unless explicitly asked.
* Never edit `AGENTS.md` unless explicitly asked.
* Never commit secrets, tokens, machine-specific paths, private exports, or debug credentials.
* Never fake metrics, progress, health states, or verification.
* Never bypass failures by hiding UI, swallowing errors, or disabling checks without justification.
* Never mark work done without verification evidence.
* Never leave stale product naming in code, docs, UI, or packaging notes.

## 8. Architecture Rules

* Keep `pcmon` local-first and lightweight.
* Prefer PowerShell-first core behavior unless the task explicitly changes architecture.
* Prefer plain HTML/CSS/JS for the dashboard until complexity clearly justifies a heavier frontend.
* Structure code so later packaging as `pcmon` CLI is easier, but do not force a rewrite just for future packaging.
* Separate concerns when safe and justified:

  * data collection
  * action handling
  * snapshot, compare, export logic
  * HTTP and API serving
  * dashboard UI
* Do not merge unrelated concerns into one giant file if a safe split is justified.
* Do not introduce heavy dependencies without a strong reason.
* Do not ship architecture theater. If a split is documented, it should exist or be clearly marked as future work.

## 9. Packaging and Run Modes

`pcmon` should support two usage modes over time.

### Direct PowerShell mode

* users can run the tool as a `.ps1` script
* this remains a first-class supported path

### Installable CLI mode

* future package-manager install should support `pcmon`
* bun is preferred, npm and pnpm are acceptable
* wrapper logic should launch the same core behavior, not a separate product

Rules:

* One core, multiple entry modes.
* Do not build two different products for script mode and package mode.
* Packaging changes must not break direct `.ps1` mode.
* Do not claim packaging readiness without real structure or clearly documented next steps.

## 10. Security Baseline

* Validate all inputs at boundaries.
* Treat process IDs, file paths, query params, export names, and action payloads as untrusted input.
* Never expose secrets, tokens, machine-only paths, or sensitive content in logs, exports, or UI unless explicitly redacted and required.
* Never use `shell: true` or shell-string execution when argument-array execution is possible.
* Validate and normalize paths before filesystem access.
* Prevent path traversal in snapshot, export, compare, and read flows.
* Use allowlists or explicit deny rules for dangerous process actions where practical.
* Clearly block or warn on risky actions against protected or critical processes.
* Do not claim security hardening without evidence.

## 11. Process Action Safety

For process kill, suspend, and resume features:

* actions must be intentionally triggered, not easy to hit accidentally
* show action results and failures clearly
* guard critical or system processes where practical
* document protected-process limitations honestly
* do not silently fail
* do not expose dangerous bulk actions without explicit user intent
* default to the safest practical behavior when uncertainty exists

## 12. Metrics and Diagnostic Quality

`pcmon` should prioritize useful diagnosis over pretty status display.

Changes should help answer:

* what is using RAM
* what is growing
* why is the system lagging
* is paging happening
* is commit pressure high
* is Defender involved
* is browser or Electron overhead involved
* is Node, Bun, or dev tooling involved
* is this potentially a kernel or driver issue
* is GPU pressure relevant

Rules:

* keep paged pool and non-paged pool visible
* keep commit and physical RAM clearly separated
* avoid misleading memory summaries
* do not hide system pressure behind oversimplified labels
* tie raw metrics to actionable interpretation where practical
* diagnostic value beats decorative UI

## 13. GPU Rules

When adding GPU support:

* start with overall GPU utilization, adapter name, and memory usage
* add temperature or per-engine metrics only when reliable
* do not ship vendor-specific logic as universal truth
* clearly label unsupported or unavailable GPU data
* avoid fragile assumptions across GPU vendors and drivers
* degrade honestly when GPU data is missing

## 14. Defender, Driver, Kernel Rules

* Defender and `MsMpEng` diagnostics should be explicit when present
* driver-leak workflows should be practical, not vague
* PoolMon helper guidance is acceptable
* do not pretend PoolMon is integrated if it is only assisted
* make kernel-memory warnings honest and interpretable

## 15. UI and UX Rules

* Keep the UI operationally useful, not flashy for its own sake.
* Every visible control must map to real behavior.
* Remove or hide placebo controls.
* Prefer clear tables, alerts, summaries, comparisons, and grouped views.
* Add empty, loading, and error states for non-trivial views.
* Long command lines should be readable without breaking layout.
* High-density views are fine if they remain understandable.
* If the UI adds complexity, prove it improves diagnosis.

## 16. Comments and Documentation

* Add short intent comments for non-trivial functions or modules.
* Explain:

  * responsibility
  * source of truth
  * important Windows, runtime, or security constraints
* Add inline comments only for non-obvious logic, invariants, fallbacks, or sensitive behavior.
* Do not add filler comments that restate obvious code.
* Keep README and runtime behavior aligned.

## 17. Refactor Rules

* Refactor in small safe steps.
* Do not mix broad cleanup with a targeted fix unless the cleanup is required for the fix.
* Do not rename and re-architect the same subsystem in one batch unless necessary.
* Do not remove old paths until all known consumers are migrated.
* If compatibility shims remain, verify both shim and canonical paths.
* Do not leave duplicate code paths without explicit ownership.

## 18. Verification Before Done

Every behavioral change must include the smallest sensible regression protection.

Required verification before finishing relevant work:

* type and lint checks if they exist in the repo
* the local script still starts
* the dashboard still loads
* the data endpoint still works
* changed tabs or views render without obvious breakage
* changed action endpoints behave as expected
* snapshot, compare, export flows work if touched
* packaging-related changes do not break direct `.ps1` mode

Ask before finishing:

* does this actually work
* did I verify the changed behavior, not just the files
* would a strong senior engineer accept this evidence

If full automation is missing, provide concrete manual validation steps.

## 19. Testing Rules

Add tests when practical for:

* metric resolvers
* snapshot, export, compare logic
* process action safety logic
* path validation
* reproduced bugs
* regression-prone parsing or grouping logic

Rules:

* do not delete or bypass failing tests just to get green status
* when fixing a bug, add the smallest sensible regression protection
* if no test harness exists, state that honestly and provide manual validation steps

## 20. Autonomous Bug Fixing

When given a clear bug report:

* investigate directly
* locate logs, errors, failing behavior, or mismatched state
* fix the bug without asking for unnecessary hand-holding
* keep the user out of context-switch loops
* resolve failing checks when possible instead of narrating the failure only

## 21. Elegance Rule

For non-trivial work, pause and ask:

* is there a simpler, cleaner solution
* is this a real fix or a patch hiding a deeper issue
* can the same result be achieved with less code or less coupling

Rules:

* prefer elegant solutions when they do not increase risk
* do not over-engineer simple fixes
* challenge your own design before presenting it

## 22. Task Management

For substantial work:

1. Plan first with checkable items.
2. Verify the plan before implementation.
3. Track progress as items complete.
4. Summarize high-level changes clearly.
5. Document results and verification.
6. Capture lessons after mistakes or corrections.

If the repo has task files such as `tasks/todo.md` or `tasks/lessons.md`, use them. If they do not exist, do not invent process overhead unless the task explicitly asks for it.

## 23. Skills and Reuse

If the repo uses skills:

* `.opencode/skills/` is the source of truth
* `.kilo/skill/` is a sync target for compatibility

Typical sync command when supported:

```bash
bun run sync:skills
```

Rules:

* create or improve reusable skills for repeated high-risk work when justified
* do not create decorative skills that add no operational value
* prefer strong reusable guidance over repeating the same mistakes

## 24. Core Principles

* **Simplicity first:** make every change as simple as possible while solving the real problem.
* **No laziness:** find root causes; do not ship temporary fixes as final work.
* **Minimal impact:** touch as little code as practical, but no less than needed.
* **Real proof:** correctness beats confidence.
* **Senior standards:** quality, honesty, and verification are mandatory.
