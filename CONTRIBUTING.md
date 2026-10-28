# Contributing

This is an independent community project. Please open an issue before a large
change, especially anything that changes routes, DNS, launchd services, or the
`tailscaled` process lifecycle.

## Local checks

On Apple Silicon macOS 15 or later:

```sh
./build.sh
./Tailbar.app/Contents/MacOS/Tailbar --self-test
codesign --verify --deep --strict Tailbar.app
```

Self-tests do not connect to a tailnet or modify VPN settings. Test network
changes separately on a machine where temporary loss of connectivity is safe.

## Translations

English is the development language. Write user-facing text in English and
pass it through `L("…")`, or `L(format: "…", value)` when it contains values;
the English text is the key. Add the translation to
`Resources/ru.lproj/Localizable.strings` with the same `%@`, `%ld` and `%d`
specifiers in the same order. A key without a translation is shown in English,
and `--self-test` checks the specifiers of every bundled translation. A new
language needs `Resources/<code>.lproj/Localizable.strings` and its code in
`CFBundleLocalizations` in `Resources/Info.plist`.

## Privacy before submitting

Do not include real account names, tailnet names, device IDs, auth URLs,
subscription URLs, proxy credentials, IP addresses, `tailscale status --json`
output, route dumps, or screenshots of a live network. Use synthetic examples.
The repository ignores the original author's local working notes; please keep
your own diagnostics outside Git as well.

By contributing, you agree to license your contribution under BSD-3-Clause.

## Releasing

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in
   `Resources/Info.plist`, move the CHANGELOG entries under the new version,
   add `release-notes/vX.Y.Z.md`, and update the ZIP name in README.md and
   docs/INSTALL.md.
2. After that lands on `main`, run the **Release** workflow (Actions tab) with
   the version. It builds and self-tests on Apple Silicon, then publishes
   `vX.Y.Z` with the ZIP, its `.sha256`, and the release notes.
