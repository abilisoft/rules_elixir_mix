"""Test-only facade for the private mix.lock parser."""

load("//bzlmod/private:mix_lock.bzl", _parse_mix_lock = "parse_mix_lock")

parse_mix_lock = _parse_mix_lock
