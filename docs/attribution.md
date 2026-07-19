<!--
SPDX-FileCopyrightText: 2026 AbiliSoft
SPDX-License-Identifier: Apache-2.0
-->

# Attribution

[Documentation home](README.md) · [License](../LICENSE) · [Notice](../NOTICE)

The project began from the RabbitMQ and Discord `rules_elixir` implementations
and studied RabbitMQ's `rules_erlang` provider and Hex repository patterns:

- <https://github.com/rabbitmq/rules_elixir>
- <https://github.com/discord/rules_elixir>
- <https://github.com/rabbitmq/rules_erlang>

Those projects are not runtime dependencies. The maintained implementation in
this repository owns its small BEAM provider, combined OTP+Elixir toolchain,
Mix rules, and pure-Starlark `mix.lock`/Hex integration.

See the root license and notice files for license details.
