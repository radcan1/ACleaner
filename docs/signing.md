# Stable local code signing

`build.sh` signs ACleaner.app with a **stable code-signing identity** so that
macOS keeps the app's Full Disk Access (and other TCC permissions) across
rebuilds. macOS ties a permission grant to the app's code signature; an
**ad-hoc** signature changes on every rebuild, which is why FDA used to need
re-granting each time.

There are two ways to get a stable identity. `build.sh` prefers the first if
it exists, and otherwise uses the second:

1. **A real Apple Development / Developer ID certificate** — created via Xcode
   (Settings → Accounts → add Apple ID → Manage Certificates → +). Requires an
   Apple ID sign-in and two-factor auth.
2. **A local self-signed certificate** (what this machine uses) — no Apple ID
   needed. It is untrusted for distribution, but it is a *stable* identity,
   which is all that TCC needs to keep the grant.

## How the local self-signed certificate was set up

A self-signed code-signing certificate named **"ACleaner Local Signing"** lives
in a dedicated keychain at `~/Library/Keychains/acleaner-signing.keychain-db`
(kept separate from the login keychain). It is scoped so only `/usr/bin/codesign`
can use its key, and its partition list is set so codesign never shows a
password prompt.

Recreate it with:

```sh
# 1. Generate a self-signed code-signing cert (valid 10 years)
cat > /tmp/acleaner_cert.conf <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = ACleaner Local Signing
[ v3 ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
openssl req -x509 -newkey rsa:2048 -keyout /tmp/acleaner_key.pem \
  -out /tmp/acleaner_cert.pem -days 3650 -nodes -config /tmp/acleaner_cert.conf
# -legacy is required so macOS's `security import` can read the bundle
openssl pkcs12 -export -legacy -inkey /tmp/acleaner_key.pem -in /tmp/acleaner_cert.pem \
  -out /tmp/acleaner.p12 -passout pass:acleaner -name "ACleaner Local Signing"

# 2. Put it in a dedicated keychain, scoped to codesign, no auto-lock
KC="$HOME/Library/Keychains/acleaner-signing.keychain-db"
security create-keychain -p acleaner "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p acleaner "$KC"
security import /tmp/acleaner.p12 -k "$KC" -P acleaner -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k acleaner "$KC"

# 3. Add it to the keychain search list (preserving existing keychains)
OIFS=$IFS; IFS=$'\n'
EXISTING=($(security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/'))
IFS=$OIFS
security list-keychains -d user -s "$KC" "${EXISTING[@]}"

# 4. Clean up the temp key material
rm -f /tmp/acleaner_key.pem /tmp/acleaner_cert.pem /tmp/acleaner.p12 /tmp/acleaner_cert.conf
```

The keychain password is a fixed local value (`acleaner`) on purpose: the
certificate is untrusted and useful only for signing this app on this machine,
so it protects nothing of value elsewhere.

## To remove it

```sh
security delete-keychain "$HOME/Library/Keychains/acleaner-signing.keychain-db"
```

After removal, `build.sh` falls back to ad-hoc signing (and FDA will again need
re-granting after each rebuild).
