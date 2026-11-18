---
name: github-ci
description: Git and GitHub rules for every SDP repo. Use before you branch, commit, push, open or update a PR, read or fix CI, or change branch protection.
---

# Git and CI

Shared by every SDP repo. The source is `.claude/skills/github-ci/SKILL.md` in `newco-sdp-core`; the other repos
carry a byte-identical copy that the `repo-policy` workflow checks. Edit it in core, then copy it over.

## Policy

- **`main` only.** No `develop`. Every change lands through a PR. A direct push to `main` needs the user's explicit
  go-ahead for that push, and only for a critical fix.
- **Branches:** `feature/`, `fix/`, `docs/`, `chore/` (tooling, dependencies, CI), `sec/` (security fixes, with
  `fix:` commits so they release), `integration/<name>` (batched small changes or a phase's slices; CI doesn't run
  until its PR, so run the local gate first). Never open a PR to `main` for one small change.
- **Every commit is signed off and signed:** `git commit -s` with `commit.gpgsign=true` (SSH or GPG key registered
  on GitHub, so it shows Verified). The `repo-policy` workflow fails a PR with any commit that is unverified or
  lacks `Signed-off-by:`. Never pass `-c commit.gpgsign=false`; if signing fails, stop and say so.
- **Conventional prefixes:** `feat:` `fix:` `perf:` `refactor:` `revert:` `build:` `docs:` `test:` `ci:` `style:`
  `chore:`. Imperative subject of 72 characters or fewer; a body that says why for anything non-trivial. In a
  repo with per-module tags, the prefix sets the bump (`RELEASING.md`). Cite plan IDs (`L4`, `SL1`).
- **Review:** one reviewer for now (one developer). Changes to tenant isolation or audit evidence (RLS policies,
  `tenantdb`, `blobstore`, `authn`, logging scrub rules, custody, purge) tick the PR template's isolation line.
- **Never** commit secrets, `.env` values, tokens or client data; rewrite history on a shared branch; skip,
  disable or quarantine a test to get green; or push an empty commit to re-run CI.
- **CI files:** Claude asks before editing `.github/workflows/` or the pre-push hook (`.claude/settings.json`).

## Doing it

1. Run the local gate: `make verify` where the Makefile has it (core installs it as the pre-push hook with
   `make install-hooks`); otherwise the checks in the repo's README.
2. Stage named files (never `git add .`), check `git diff --cached --stat`, commit with `-s`.
3. Push with `git push -u origin <branch>`. Open the PR against `main`; the body follows
   `.github/pull_request_template.md`.
4. Watch: `gh pr checks <n>`. On a failure, `gh run view <run-id> --log-failed > <scratch>/ci.log`, read the
   failing lines, fix the root cause, re-run that check locally, push. One re-run at most for a suspected flake.
5. Done when every check is green, there is no conflict and the template is filled in.

The jobs a repo runs are the files in its `.github/workflows/`; read them rather than relying on a list here.

## Branch protection

The `vdatacloud` org is on a paid plan, so every repo can protect `main`. The settings live in GitHub, not here;
check them with `gh api repos/vdatacloud/<repo>/branches/main/protection`. Required checks are the stable job
names (`Signed commits` everywhere, `Shared files` outside core); matrix job names change with the modules and are
not required. Changing protection is a user decision: propose it, don't apply it unasked.
