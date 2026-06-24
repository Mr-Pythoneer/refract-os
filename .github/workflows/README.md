# CI

`shellcheck.yml` — two jobs, on every push/PR:
- `shellcheck`: finds every script by its shebang, runs shellcheck (warning severity) + `bash -n` on all of them
- `validate-yaml`: parses every Calamares config file as YAML

## What this catches, and what it can't

This is genuinely all the automated testing possible without real hardware
(no GPU server, no test VM, no live desktop — see DESIGN.md). It catches
syntax errors and lint-level issues. It does **not** catch logic bugs —
notably, it would NOT have caught the `set -e` + trailing-`&&`-chain bugs
found and fixed during a manual bash-5 execution pass (see TODO.md, "CI /
quality" section): `bash -n` only parses, it doesn't execute, so a script
that's syntactically valid but silently swallows a failed `apt-get update`
because it's the non-last command in a `&&` chain will pass this CI clean
and still be wrong. Actually running scripts (even partially, even outside
their target environment) found bugs that static analysis didn't.
