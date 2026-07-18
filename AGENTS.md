# Agent instructions

## Documentation

Use Context7 MCP for current library, framework, SDK, API, CLI, and cloud
service documentation. Resolve the library ID before querying its docs. Do not
use Context7 for ordinary refactors, repository-local business logic, or code
review.

Follow `/home/silkrad/.codex/RTK.md`; prefix shell commands with `rtk`.

## Repository publishing

- The canonical GitHub repository is `abilisoft/rules_elixir_mix` and must
  remain private unless the user explicitly changes its visibility.
- Agents may create and push this repository when the user requests it.
- Never add AI/agent attribution, `Co-authored-by`, or similar generated
  trailers to commits, pull requests, or release notes.
- Before pushing, audit the commits being published for unwanted attribution
  and inspect the staged file set for generated outputs, credentials, and
  local caches.
