# Security Policy

## Reporting a vulnerability

Please report security issues privately by opening a
[GitHub security advisory](https://github.com/getathelas/LoopHarness/security/advisories/new)
on the repository (or email the maintainer) rather than filing a public issue.
We aim to acknowledge reports within a few days.

## Credential model

LoopHarness never bundles API keys. Keys are entered in-app and stored in the
Apple Keychain (`LoopIOS/Settings/KeyStore.swift`). `Info.plist` entries use
`$(VAR)` placeholders, which `KeyStore` treats as *absent* — falling back to
the in-app entry flow. Nothing in this repository is a live credential.

## Automated scanning

Every push and pull request runs Gitleaks
(`.github/workflows/secret-scan.yml`). A detected secret fails CI.
