# AI Planner R72 — route application parity

## Objective

Ensure a route applied by `Candidate.Apply` produces the same passive allocation and native PoB metrics that were used to approve its exact preview.

## Fix

- Reuse the `PassiveSpec` projection that built the candidate for exact evaluation, including legal connector nodes, instead of reconstructing the applied undo state from only requested target IDs.
- When character level is in Auto mode, apply the exact evaluated level and rebuild configuration modifiers before PoB refreshes output.
- Extend the disposable HeadlessWrapper smoke to compare the projected and applied node sets and native metric values after PoB's output refresh.

## Validation

- Full PoB release base: 2.67.2; full package manifest: 1,480 files.
- UI and socket-scope suites: 27/27 passed. Linked-support and route-composition suites: 20/20 passed, run in separate processes as required by their fixtures.
- Disposable Lightning Conduit route search: 40,000 structural proposals, 39,417 unique, 326 retained, 226 exact calculations completed before the search time limit, and 11 exact Pareto routes returned.
- Applying Pareto route 2 created a new reversible variation. Its 131 allocated nodes matched the preview, the Auto level matched at 98, and all 19 available native metric comparisons matched exactly.
- The imported source build remained unchanged. Search ended at its time limit, so the 250 exact-evaluation budget was not fully consumed; the route result is valid, but the search was bounded rather than exhaustive.
- The validated R72 full package was installed into the existing PoB 2.67.2 installation. The installer verified program and runtime files, kept the official executable unchanged, preserved `OptimizerStudies`, `Path of Building`, and `installed.cfg`, and created a rollback backup.

## Scope

This validates application parity for the selected route fixture and checks the packaged full-release installation. It does not claim that every route family, build, skill, or candidate can be searched exhaustively.
