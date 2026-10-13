<p align="center">
  <img src="Resources/AppIcon/AppIcon.png" alt="macOS KDX icon" width="128">
</p>

# macOS KDX

A native macOS client and server for Haxial KDX, written in Swift 6. Both apps use AppKit
to recreate the original themed interfaces and share the same Swift protocol
implementation. No third-party Swift package dependencies. Original KDX assets
are extracted from a required local archive when building the apps.

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
- **Archive tool:** `unar` (`brew install unar`).
- **Original assets:** `KDX_1.6_OSX_intel.7z`, supplied as the build argument.
  The build extracts all client/server appearances, artwork, fonts, and the
  challenge table from this one archive and bundles the verified data in both apps.
  No separate appearance import or challenge-table download is needed.

## Quick start

### Build the apps

From the repository root:

```sh
scripts/build-apps.sh "$HOME/Downloads/KDX_1.6_OSX_intel.7z"
```

This creates `dist/KDX Client.app` and `dist/KDX Server.app`. Every build requires
and verifies the archive; no previous asset cache is required. Extraction reads
only the two KDX executables as data and never launches them or includes Wine.
The supported archive SHA-256 is
`b35e72925181e0044f3d6f587fa249d86df59965a5a07bd4e0843962fb286152`.
You can also open `Package.swift` in Xcode to work on the source.

### Connect or host

1. Open KDX Client or KDX Server. The bundled challenge table is used automatically.
   Existing manually imported tables take precedence. Import/download commands
   remain available for development builds and recovery; see [table setup](docs/TABLE-IMPORT.md).
2. To host, open KDX Server. Its window menu (also available as the macOS
   **Server** menu) provides **Settings** for administrator credentials and port,
   **Server Settings…** for name/shared folder/guests, **Accounts…**, and
   **Challenge Table…**. Choose **Start Server** when ready.
3. In KDX Client, open **Connect…** to browse the default Higher Intellect Tracker
   or connect directly to a server. Use `127.0.0.1` for a server on the same Mac;
   leave login and password blank for guest access.
4. Use the floating bar for chat, users, messages, files, and transfers. Choose a
   theme under **KDX Client → Appearances…**.

See the [client guide](docs/CLIENT.md#use) and [server guide](docs/SERVER-UI.md) for controls and workflows.

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
| `Sources/KDXServer/` | AppKit server entry point |
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
are not included in the repository. Appearance data and the challenge table are
extracted locally at build time and included in the resulting app bundles; the
original programs are never launched by the importer.
