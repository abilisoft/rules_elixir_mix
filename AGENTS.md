# Agent instructions

## Documentation

Use Context7 MCP for current library, framework, SDK, API, CLI, and cloud
service documentation. Resolve the library ID before querying its docs. Do not
use Context7 for ordinary refactors, repository-local business logic, or code
review.

Follow `/home/silkrad/.codex/RTK.md`; prefix shell commands with `rtk`.

## Working policy

- Work on a branch and through a pull request. Do not make feature, fix,
  documentation, CI, or cleanup changes directly on `main`.
- Treat failed validation as a defect to fix. Never weaken, bypass, or remove a
  required check merely to make CI pass.

## Repository publishing

- The canonical GitHub repository is `abilisoft/rules_elixir_mix` and must
  remain private unless the user explicitly changes its visibility.
- Agents may create and push this repository when the user requests it.
- Never add AI/agent attribution, `Co-authored-by`, or similar generated
  trailers to commits, pull requests, or release notes.
- Before pushing, audit the commits being published for unwanted attribution
  and inspect the staged file set for generated outputs, credentials, and
  local caches.

## Git and attribution

- Every commit must follow Conventional Commits and must be cryptographically
  signed with the configured Git identity and signing key.
- Before publishing, verify every new commit locally and confirm GitHub reports
  it as `verified`. If signing cannot be completed or verified, stop and ask;
  never fall back to an unsigned commit.
- Never add `Co-authored-by` or any other co-author, AI, agent, or generated
  attribution trailer. This prohibition is absolute.
- Audit the complete live history for author and committer identity, signature
  status, Conventional Commit subjects, and unwanted attribution trailers.
- Never rewrite published history or force-push as a surprise. Present the
  exact rewrite and obtain explicit approval before changing live commit IDs.
