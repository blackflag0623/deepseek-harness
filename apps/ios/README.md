# Whale Girl for iOS

English | [中文](README.zh.md)

Whale Girl (`鲸鱼娘`) is a private SwiftUI frontend for a dsh Web Host running on a development machine. The iPhone stores presentation state and the Host-issued browser cookie; model requests, tools, source files, Sessions, and durable history stay on the Host.

Its app icon uses the selected blue whale-hood mascot artwork generated for this private client.

## Use

Open `鲸鱼娘.xcodeproj` in Xcode and run the `WhaleGirl` scheme on an iPhone with iOS 17 or later. Start the dsh Web Host through an HTTPS tunnel that forwards to its loopback listener, then paste the complete URL printed by `dsh web`, including the one-time `token` query, into the connection screen. The app exchanges that token for the normal authority-bound dsh browser cookie and stores only the clean Host URL.

The sidebar groups every visible Session by its Host `cwd`, shows the five most recently updated Sessions in each group, and expands older entries on demand. Selecting a Session opens its current history, pages older messages, and follows later durable events plus live assistant stream frames. The composer sends queued text prompts and can cancel the running turn. Every user and assistant bubble renders GitHub-flavored Markdown, including horizontally scrollable tables and styled code blocks. Reasoning and tool calls update inside an expandable execution panel. Long-pressing a message bubble opens the standard Copy and Select Text actions, and Select Text opens a native selectable view for copying a precise range.

## Architecture

The app calls the existing Typert Gateway without a mobile-specific business backend. Unary operations use the authenticated `/api/<namespace>/<method>` envelope, and each live Session uses the Gateway's `/api/remote.stream` HTTP NDJSON carrier for `session/follow`. A Host without that carrier is rejected with upgrade guidance instead of entering an unreliable WebSocket retry loop. `ConversationProjection` derives the mobile timeline from Session events and transient assistant frames; reconnecting replaces the timeline from the next authoritative snapshot.

The app accepts HTTPS in all builds. Debug builds also accept HTTP for local development, while the application transport policy permits local networking only. A remote deployment remains responsible for TLS termination and forwarding to the loopback-only dsh Web listener.

## iOS lifecycle and recovery

The foreground owns the live `session/follow` socket. Entering the background, including locking the phone, cancels and awaits that follower without sending `session/cancel`; the Host Agent and its durable Session continue independently. Returning active immediately opens a fresh follower, whose opening snapshot replaces the visible tail before incremental events resume. The current conversation stays visible during this recovery.

A force quit gives the app no guaranteed cleanup callback. The operating system closes its transport, while the Host continues running. On the next launch, the persistent dsh browser cookie reconnects, the Session list refreshes, and the last selected Session reopens when it still exists.

Transport failures such as connection abort, timeout, or network loss are automatic-recovery states. They show an animated reconnecting banner with no modal alert. Authentication, protocol, and Host business failures stop automatic retries and show an actionable message with Retry or connection-setting guidance.

Early-development diagnostics are checked in. Structured OSLog categories cover app, lifecycle, transport, Session state, and interaction milestones without recording Host URLs, cookies, Session ids, paths, or message content. Debug builds mirror recovery-critical events to the attached device console and disable the idle timer so a connected acceptance run remains observable.

## Current scope

- Browse, search, create, and open Sessions across Host working directories.
- Send text prompts, stop active work, and reconnect without stopping the Host Session.
- Present Markdown user and assistant bubbles, streaming text, reasoning, tool arguments, tool results, and turn outcomes.

Workspace editing, file transfer, approvals, voice, notifications, Watch support, and App Store distribution are outside this client.

## Develop

Build the app without code signing:

```sh
xcodebuild -project 'apps/ios/鲸鱼娘.xcodeproj' -scheme WhaleGirl -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Run the projection tests on an installed simulator:

```sh
xcodebuild -project 'apps/ios/鲸鱼娘.xcodeproj' -scheme WhaleGirl -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO test
```

The [native iOS client Agent Note](../../.agents/notes/implemented/feature/2026-09-12-native-ios-client.md) records the product boundary and rejected alternatives.
