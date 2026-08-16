# Signing updates

`distro-update` downloads code and installs it as **root**. Until this existed,
the only thing vouching for that code was HTTPS — which proves you reached
github.com, not that the bytes are the ones this project published. Anything
that can terminate TLS (a school or corporate proxy whose certificate authority
is installed on the machine — normal, and exactly where these laptops live)
could have handed a Refract machine arbitrary code and it would have run as root.

Ubuntu's own updates are signed. Refract's now are too.

## How it works

- An **Ed25519 key pair**. The private half exists in exactly one place: the
  `REFRACT_SIGNING_KEY` GitHub Actions secret. The public half is committed at
  `iso/keys/refract-signing.pub` and ships in every image at
  `/usr/share/refract/refract-signing.pub`.
- On every push to `main`, `.github/workflows/sign-layer.yml` builds a
  **deterministic** tarball of the update payload, writes a manifest naming its
  SHA-256, signs the manifest, and publishes all three to the rolling
  `layer-latest` release.
- `distro-update apply` verifies the manifest's signature against the **local**
  public key, then checks the tarball's digest against that signed manifest, and
  only then extracts anything. Any failure aborts before a single file is
  touched.

Why not GPG: `openssl` is already on every image and `gnupg` is not guaranteed on
the slimmer strains. Adding a package in order to make updates verifiable would
be a strange trade for 113 bytes of key.

Why our own tarball rather than GitHub's `codeload` archive: those are generated
per request, not stored. GitHub has changed its compression before and silently
broken everyone's recorded checksums. A digest over that file is a promise that
cannot be kept.

## Setting it up (once)

**1. Generate the pair.** On your own machine, in a directory that is *not* the
repo:

```bash
openssl genpkey -algorithm ed25519 -out refract-signing.key && openssl pkey -in refract-signing.key -pubout -out refract-signing.pub && chmod 600 refract-signing.key && cat refract-signing.pub
```

**2. Commit the public half.** Copy `refract-signing.pub` into the repo at
`iso/keys/refract-signing.pub` and push it. It is public; there is nothing to
protect.

**3. Add the private half as a secret.** In the repo on github.com:
Settings → Secrets and variables → Actions → New repository secret.
Name it `REFRACT_SIGNING_KEY` and paste the **entire** contents of
`refract-signing.key`, including the `-----BEGIN PRIVATE KEY-----` and
`-----END PRIVATE KEY-----` lines.

Or from a terminal:

```bash
gh secret set REFRACT_SIGNING_KEY --repo Mr-Pythoneer/refract-os < refract-signing.key
```

**4. Keep the private key somewhere safe and offline**, then delete it from the
working directory. A password manager or an encrypted backup is fine. You need
it again only if you ever want to sign from somewhere other than CI.

That is the whole setup. The next push publishes a signed layer.

## Until step 3 is done

`sign-layer.yml` **skips quietly** while neither the key nor the public key
exists — no red X on every push — and `distro-update` keeps using the old
unsigned path with a visible warning.

The moment `iso/keys/refract-signing.pub` is committed, the workflow starts
failing loudly if the secret is missing. That is deliberate: once shipped images
expect a signature, publishing an unsigned layer would put an unverifiable
tarball at the URL those machines now trust — worse than not publishing.

## The first update is unverified, and that is unavoidable

A machine installed before signing existed carries no public key, so it has
nothing to verify against. That one update is the one that installs the key;
every update after it is checked. `distro-update` says so on screen rather than
passing over it.

This is the same shape as SSH's trust-on-first-use. The alternative — refusing to
update a machine with no key — would strand every existing install on the
unsigned path permanently, which is not more secure, just more final.

## If the key leaks

Anyone holding it can sign updates that every Refract machine will accept, so
treat it as the most sensitive thing in the project.

1. Generate a new pair (step 1).
2. Replace `iso/keys/refract-signing.pub` and the `REFRACT_SIGNING_KEY` secret.
3. **Rebuild and republish every ISO.** Existing installs will reject updates
   signed by the new key, because they still hold the old public key.
4. Those machines need one manual step to recover:
   ```bash
   sudo curl -fsSL https://raw.githubusercontent.com/Mr-Pythoneer/refract-os/main/iso/keys/refract-signing.pub -o /usr/share/refract/refract-signing.pub
   ```
   That is trust-on-first-use again and it is the honest cost of a key
   compromise. There is no rotation path that avoids it without a second,
   already-trusted key — which would be worth adding if this distro ever has
   users who are not reachable directly.

## Checking it yourself

```bash
distro-update check
```

On a machine with the key, that answer now comes from the **signed** manifest
rather than from an unauthenticated API — so nobody can pin a machine at an old
build by lying about what the latest one is.

To confirm the mechanism end to end, `tests/test_update_signing.sh` generates a
throwaway key, signs a manifest, and asserts that the real verifier accepts it
and rejects an edited manifest, a signature from another key, a truncated
signature and an empty one.
