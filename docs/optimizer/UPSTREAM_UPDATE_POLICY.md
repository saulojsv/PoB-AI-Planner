# AI Planner protection across PoB updates

## Protection already active in managed releases

The managed release marker is checked by both `src/UpdateCheck.lua` and `src/Launch.lua`. While the marker is present, PoB's built-in updater refuses to replace the managed program files. This prevents an update from silently overwriting the AI Planner integration.

This is a protection mechanism, not an automatic update path. The managed build stays on its current PoB version until the upstream changes have been integrated, validated, packaged, and installed as a new managed release.

## Automatic compatibility check

`.github/workflows/pob-upstream-compatibility.yml` checks official `master` and `dev` daily and on each `main` push or pull request. For each branch, the job:

1. Fetches the official branch into an isolated CI checkout.
2. Attempts a temporary Git merge with the Planner branch. Conflicts fail the check and identify files needing manual reconciliation.
3. Runs the PoB LuaJIT test suite against the merged tree.

The workflow has read-only repository permissions. It does not merge, push, install, or publish. A green run means that the tested upstream commit merged cleanly and the test suite passed; it does not certify every live-build behavior, so the packaged build still needs its native QA checks.

## Updating the Planner after an upstream release

1. Close PoB and create a maintenance branch from `main`.
2. Fetch the official upstream and merge the released `master` commit (or the required `dev` commit) into that branch.
3. Resolve any conflicts in AI-owned files, update their manifest hashes, and run the upstream test suite plus the optimizer contracts listed in the current release report.
4. Build a full managed release, verify every manifest entry and the executable hash, and install it using the backup-capable installer.
5. Confirm the installation and record the source commit, PoB version, test results, and backup location before merging the maintenance branch to `main`.

The official source remote is `https://github.com/PathOfBuildingCommunity/PathOfBuilding.git`. In a clone of this repository, configure it as `upstream` and use the compatibility workflow before preparing a release. Do not pull official files directly into the installed application directory.

## Source and data boundary

The public repository contains code, schemas, and synthetic test fixtures. Never commit personal builds, build XMLs, share codes, imported account/profile data, raw observation records, training shards, model weights, or Drive exports here. Keep those in the project's designated local/Drive storage and publish only the software source needed to reproduce the pipeline.
