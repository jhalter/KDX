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
5. Use Chat, Files, News, and Accounts. Right-click a user for private messaging or user information. Use My Profile to edit your nickname/about-me text and the Away toggle to update your status. The default guest class can chat, read news, and download; the default member class can also upload and post news. Account overrides can allow or deny individual privileges. Administrators can manage accounts remotely and edit inherited permissions through the Accounts → Classes menu, and members can change their own passwords. Use the Groups menu in News to create, edit, or delete newsgroups, set class access, and control storage limits. Use the plus button to create a room, right-click a room to edit or delete it, and use the Room menu to create a private chat, invite users, set its topic, or leave.

Settings, account keys, news, and the imported table reside in `~/Library/Application Support/macOS-KDX/`. Client passwords are not persisted. Server account keys are password-equivalent credentials stored in an owner-readable settings file. KDX's historical SHA-1/Twofish protocol is preserved for compatibility; it does not provide modern authenticated transport security.

Downloads and uploads never replace an existing destination. Pick a new destination name if one already exists. The server resolves shared paths with descriptor-relative operations and rejects symlinks and traversal. Interrupted uploads from named accounts retain private staging files under `.kdx-uploads` in the destination folder and resume after reconnecting or restarting the server. Staging is isolated by account and never appears in shared listings. Anonymous uploads are discarded on disconnect. Resume the same unchanged source; the legacy protocol does not send a content hash, so choose a new name if its contents changed. Removing `.kdx-uploads` while the server is stopped discards those saved partial uploads. Interrupted downloads retain an owner-readable checkpoint in a hidden `.kdx-downloads` folder beside the destination. Select the same destination on the same server/account to resume, including after reconnecting or restarting the client. If the remote size, timestamps, or metadata changed, the partial is discarded and a retry starts fresh. Completed downloads retain the remote modification time. Both data and resource forks are streamed and preserved; download retries resume each fork separately, while upload retries restart the resource fork as KDX specifies. Each fork is limited to 4 GiB minus one byte. Finder type/creator metadata and comments are not yet mapped. Removing `.kdx-downloads` while no transfer is running discards its saved partial downloads.

## Implemented

- Separate SwiftUI client and server apps, connection state, error reporting, persisted connection fields and server settings.
- KDX hello/proof authentication, challenge-table extraction/verification, account-key derivation, Twofish-256, header scrambling, and encrypted message framing.
- Remote account list/create/edit/rename/delete, class info/list/edit, per-account privilege overrides, and password changes. Changes are persisted before acknowledgment and propagated to logged-in sessions; account info exposes only a password-present flag. Existing settings migrate automatically.
- Connection, handshake, payload, and transfer I/O deadlines; cancellable I/O; bounded pending requests; stale request/session cleanup.
- Multi-client server, profile editing, away/back status, detailed user information with permission checks, public chat, private messages, local server disconnect controls, ping and request/reply correlation. Profile updates reach the sender as well as peers; account nickname restrictions remain enforced. User records preserve legacy icon/color fields without trusting client-supplied admin badges.
- Persistent named chat rooms with remote creation/editing/deletion, per-class join/send/topic access, live membership tracking, and topic changes. Room and account access changes revoke membership immediately. Private chats support creation, targeted invitations with Accept/Decline, key-protected joins, and automatic deletion when empty. Invitation message text and voice are not implemented; see [private-chat evidence](docs/PRIVATE-CHAT-PROTOCOL.md).
- File browsing and encrypted streaming of both Mac file forks on authenticated transfer connections, with persistent upload/download resume at KDX block boundaries and modification-date preservation. Transfer sessions use the session key and must originate from the parent connection's IP. Uploads require the upload privilege.
- News listing, reading, posting, latest-own-post/admin deletion, change notifications, persistent group administration, class access, storage budgets, and large-list handling. See [newsgroup protocol evidence](docs/NEWS-PROTOCOL.md).
- Import of an existing KDX binary or raw challenge table; protocol-compatible credentials, not a custom login protocol.

## Verification

`ProtocolTests` includes a Twofish known-answer vector and independent captured traffic from the reference. It reproduces both handshakes, authentication proofs, and every encrypted message in the first-connect fixture byte for byte. User tests additionally reproduce captured identity, user-list, and detailed-information records byte for byte, including icon and color data. Chat and account tests additionally compare chat windows, topics, room records/lists, accounts, classes, and account lists against independently captured reference traffic. Transfer fixtures also cover full downloads, a non-aligned resume request, and an end-of-file resume, including their independent attachment session keys. Upload request/reply/data/completion fixtures are checked as well. Private-room creation and invitations, class-edit requests and success replies, plus newsgroup creation/info/edit/delete/list records, are also checked against extracted reference captures. No challenge table is needed for these fixture tests.

The headless integration suite exercises actual client/server session code over a fragmented in-memory byte transport. It checks multi-client chat and private messages, authentication rejection, news ownership/persistence, and upload/download integrity across multiple cipher chunks. Filesystem tests cover traversal, symlinks, overwrite refusal, and temporary-file cleanup. Account tests cover persistence rollback on write failure, privilege escalation rejection, old-password rejection, connected-session updates, protected account deletion, and persisted class edits with immediate member/guest revocation and preserved overrides. Chat tests cover room persistence/rollback, message isolation, topic delivery to new members, membership cleanup, deletion, and live permission revocation. Private-chat tests check invitation targeting, key validation, isolation, decline, creation limits, and empty-room cleanup after leaving, disconnecting, or revocation. Lifecycle tests cover stalled I/O, cancellation, timed-out requests, and replacing an in-progress login. Transfer tests interrupt actual streams after partial data, verify resumed byte counts/integrity, enforce exclusive checkpoint access, reject changed files and symlinks, verify upload recovery across a server restart, account isolation, anonymous cleanup, and non-overwrite behavior, and reconnect while an older transfer is still unwinding. Resource-fork tests compare against macOS named-fork file access and cover multi-chunk upload/download, resource-only files, separate resource download resume, and interrupted resource uploads. Nonempty resource-fork interoperability with a legacy Mac peer remains unverified; the reference fixtures come from Linux and contain empty resource forks. File/news dates now use the reference’s inferred 1900 epoch; its timestamp example is consistent with the capture year. User tests verify profile/status broadcasts, nickname restrictions, user-info denial and missing-user errors, and resistance to forged administrator markers. News tests cover class access, post-only groups, storage pruning, migration, failed-write rollback, and replies larger than 1 MiB. A synthetic table is available only to internal test code, never to the apps' import path.

Real TCP remains a separate test gate:

```sh
KDX_TEST_TCP=1 scripts/test.sh
```

The implementation environment currently denies TCP listener creation with `EPERM`. The opt-in test is therefore explicitly skipped in the default suite; passing the default suite does **not** establish live TCP interoperability. The apps have been compiled but not launched or visually inspected. A real challenge table and live reference/legacy peers are also still needed for a complete interoperability audit.

See [implementation status](docs/STATUS.md) for remaining work and completion gates.

## Source attribution

The protocol and captured test fixtures derive from scottanderson/kdx (MIT license in `Notices/KDX-MIT.txt`). The Swift Twofish implementation adapts RustCrypto's Twofish algorithm (MIT license in `Notices/RustCrypto-MIT.txt`). These notices are included in the app bundles. The original Haxial programs and complete challenge table are not included.
