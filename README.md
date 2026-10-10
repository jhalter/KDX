# macOS KDX

Native macOS client and server applications written in Swift 6 and SwiftUI, with a shared Swift implementation of the Haxial KDX wire protocol. Requires macOS 14 or later and Xcode with Swift 6 support. No external package dependencies.

This is an implementation in progress, not yet a fully verified replacement for every original KDX feature. Protocol work follows [scottanderson/kdx](https://github.com/scottanderson/kdx), pinned to `9807f42efeb565df8b92741074fdcd625bb24d16`. The reference's server crate is a placeholder; this repository implements its own server.

## Build

```sh
scripts/test.sh
scripts/build-apps.sh
```

The build script creates ad-hoc-signed `dist/KDX Client.app` and `dist/KDX Server.app`. It does not launch them. These are local development builds, not notarized distribution releases. The package can also be opened in Xcode by selecting `Package.swift`.

## First use

1. Obtain an original, uncompressed KDX executable or the `challenge-table.bin` exported by the reference client's `kdx table import` / `kdx table fetch` commands.
2. Use **Import KDX Binary or Table…** in either app. The importer checks the table's SHA-256 before storing it. Both apps use the same local table. The copyrighted table is not distributed here; importing a ZIP directly is not supported yet.
3. In KDX Server, choose a name, port, shared folder, and accounts. Enable guest access if desired, then start the server. Account settings are editable while stopped.
4. In KDX Client, enter the host (use `127.0.0.1` for the same Mac), port, account/password, and nickname. An empty account/password requests guest access.
5. Use Chat, Files, and News. Right-click a user for private messaging. Guests can chat, read news, and download; named accounts can also upload and post news.

Settings, account keys, news, and the imported table reside in `~/Library/Application Support/macOS-KDX/`. Client passwords are not persisted. Server account keys are password-equivalent credentials stored in an owner-readable settings file. KDX's historical SHA-1/Twofish protocol is preserved for compatibility; it does not provide modern authenticated transport security.

Downloads and uploads never replace an existing destination. Pick a new destination name if one already exists. The server resolves shared paths with descriptor-relative operations and rejects symlinks and traversal. Interrupted uploads use temporary files that are removed when the connection is released.

## Implemented

- Separate SwiftUI client and server apps, connection state, error reporting, persisted connection fields and server settings.
- KDX hello/proof authentication, challenge-table extraction/verification, account-key derivation, Twofish-256, header scrambling, and encrypted message framing.
- Multi-client server, identity/user list updates, public chat, private messages, disconnect controls, ping and request/reply correlation.
- File browsing and encrypted streaming upload/download on authenticated transfer connections. Transfer sessions use the session key and must originate from the parent connection's IP. Uploads require a named account.
- News listing, reading, posting, ownership/admin deletion, change notifications, and server-side persistence.
- Import of an existing KDX binary or raw challenge table; protocol-compatible credentials, not a custom login protocol.

## Verification

`ProtocolTests` includes a Twofish known-answer vector and independent captured traffic from the reference. It reproduces both handshakes, authentication proofs, and every encrypted message in the first-connect fixture byte for byte. No challenge table is needed for these fixture tests.

The headless integration suite exercises actual client/server session code over a fragmented in-memory byte transport. It checks multi-client chat and private messages, authentication rejection, news ownership/persistence, and upload/download integrity across multiple cipher chunks. Filesystem tests cover traversal, symlinks, overwrite refusal, and temporary-file cleanup. A synthetic table is available only to internal test code, never to the apps' import path.

Real TCP remains a separate test gate:

```sh
KDX_TEST_TCP=1 scripts/test.sh
```

The implementation environment currently denies TCP listener creation with `EPERM`. The opt-in test is therefore explicitly skipped in the default suite; passing the default suite does **not** establish live TCP interoperability. The apps have been compiled but not launched or visually inspected. A real challenge table and live reference/legacy peers are also still needed for a complete interoperability audit.

See [implementation status](docs/STATUS.md) for remaining work and completion gates.

## Source attribution

The protocol and captured test fixtures derive from scottanderson/kdx (MIT license in `Notices/KDX-MIT.txt`). The Swift Twofish implementation adapts RustCrypto's Twofish algorithm (MIT license in `Notices/RustCrypto-MIT.txt`). These notices are included in the app bundles. The original Haxial programs and complete challenge table are not included.
