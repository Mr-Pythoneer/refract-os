# Signing keys

`refract-signing.pub` is the Ed25519 **public** key every Refract image carries at
`/usr/share/refract/refract-signing.pub`. `distro-update` verifies each update's
manifest against it and refuses to install anything that does not check out.

The matching **private** key never appears in this repo. It lives in one place —
the `REFRACT_SIGNING_KEY` GitHub Actions secret — and is used only by
`.github/workflows/sign-layer.yml`.

See `docs/signing.md` for how to generate the pair and what to do if it leaks.

Until the key exists, `sign-layer.yml` fails closed and publishes nothing, and
`distro-update` falls back to the old unsigned path with a loud warning. That is
deliberate: publishing an unsigned tarball to the URL clients are about to start
trusting would be worse than not publishing at all.
