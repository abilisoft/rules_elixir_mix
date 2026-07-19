# Agent instructions

## Documentation

Use Context7 MCP for current library, framework, SDK, API, CLI, and cloud
service documentation. Resolve the library ID before querying its docs. Do not
use Context7 for ordinary refactors, repository-local business logic, or code
review.

## Working policy

- Work on a branch and through a pull request. Do not make feature, fix,
  documentation, CI, or cleanup changes directly on `main`.
- Treat failed validation as a defect to fix. Never weaken, bypass, or remove a
  required check merely to make CI pass.

## Repository publishing

- The canonical GitHub repository is `abilisoft/rules_elixir_mix` and is
  public. Do not change its visibility without explicit user approval.
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

## Repository privacy

- Never store a person's username, name, email address, signing-key path,
  home-directory path, hostname, or other machine-local identity in tracked
  files.
- Organization-owned project coordinates and project contact addresses are
  allowed when required for repository metadata, support, or security reports.
- Keep local tool configuration, credentials, cache paths, and agent-specific
  instructions outside the repository.
- Before every commit, search the staged content for personal identities,
  absolute local paths, credentials, generated artifacts, and local caches.
