<p align="center">
  <img src="Resources/AppIcon/AppIcon.png" alt="macOS KDX icon" width="128">
</p>

# macOS KDX

A native macOS client and server for Haxial KDX, written in Swift 6. The AppKit
client recreates the original themed interface; the SwiftUI server shares the
same Swift protocol implementation. No external package dependencies.

## Status

The client supports tracker browsing, multiple server connections, chat, private
messages, file browsing, folder access, file operations, catalog/search, and
resumable uploads and downloads. Local builds bundle
all 16 original appearances, with Mach Lavender selected by default.

Compatibility is incomplete. News and advanced remote administration have core
and server support but still need client views. Visual fidelity and full
interoperability with legacy peers remain unverified. KDX preserves its historical
SHA-1/Twofish protocol and does not provide modern authenticated transport security.

See the [October protocol update](docs/UPSTREAM-UPDATE.md) for the latest changes,
the [implementation status](docs/STATUS.md) for supported features and remaining
work, and the [interoperability checklist](docs/INTEROPERABILITY.md) for verification
limits.

## Requirements

- **Platform:** macOS Tahoe 26 or macOS Golden Gate 27.
- **Build tools:** Xcode with Swift 6 support and the macOS 26 SDK or later.
- **Original appearances:** an original KDX Client 1.600 application or archive
  for the first app-bundle build. Later builds can reuse the validated
  `.build/OriginalAppearances.json` cache.
- **Authentication:** the original KDX challenge table, downloaded or imported
  through either app. It is not included in this repository.

## Quick start

### Build the apps

From the repository root:

```sh
KDX_REFERENCE="/path/to/original/KDXClient.app" scripts/build-apps.sh
```

This creates `dist/KDX Client.app` and `dist/KDX Server.app`.
You can also open `Package.swift` in Xcode to work on the source.

### Connect or host

1. Open KDX Client or KDX Server and choose **Download Challenge Table**, or use
   **Import Challenge Table…** with an original executable, ZIP archive, or exported
   table. Both apps share the imported table. See [table setup](docs/TABLE-IMPORT.md).
2. To host, open KDX Server, configure a name, port, shared folder, and accounts,
   then start the server. Enable guest access if desired.
3. In KDX Client, open **Connect…** to browse the default Higher Intellect Tracker
   or connect directly to a server. Use `127.0.0.1` for a server on the same Mac;
   leave login and password blank for guest access.
4. Use the floating bar for chat, users, messages, files, and transfers. Choose a
   theme under **KDX Client → Appearances…**.

See the [client guide](docs/CLIENT.md#use) for controls and workflows.

## Tests

Run the local, headless suite from the repository root:

```sh
scripts/test.sh
```

The default suite covers captured protocol fixtures, in-memory client/server
sessions, file transfers, and offscreen UI rendering. It does not contact public
endpoints or require a challenge table. Reference-dependent tests skip when their
inputs are absent.

To include the local TCP test in an environment that permits listeners:

```sh
KDX_TEST_TCP=1 scripts/test.sh
```

See the [live verification instructions](docs/INTEROPERABILITY.md) for testing
against independent servers and trackers. Passing the default suite does not
establish live interoperability.

## Code and documentation

| Path | Contents |
| --- | --- |
| `Sources/KDXCore/` | Shared protocol, client/server sessions, authentication, and transfers |
| `Sources/KDXClientUI/` | AppKit interface and original appearance renderer |
| `Sources/KDXClient/` | Client app entry point |
| `Sources/KDXServer/` | SwiftUI server app |
| `Sources/KDXAppearanceTool/` | Appearance extraction and validation |
| `Tests/` | Protocol fixtures, integration tests, and UI tests |
| `scripts/` | Build, test, and interoperability commands |
| `docs/` | Setup guides, protocol evidence, and implementation status |

## Software updates and releases

The build script produces ad-hoc-signed local development apps. These are not
notarized distribution releases.

## License and credits

Protocol work and captured fixtures derive from
[scottanderson/kdx](https://github.com/scottanderson/kdx), pinned to
`b9777a3f6c95fb1c20845958efaab05e75bcec33`; see its
[MIT notice](Notices/KDX-MIT.txt). The Swift Twofish implementation adapts
RustCrypto's algorithm; see its [MIT notice](Notices/RustCrypto-MIT.txt).
Both notices are included in app bundles.

The original Haxial programs, appearance assets, and complete challenge table
are not included in the repository. Appearance data is imported locally at build
time; the original programs are never launched by the importer.
