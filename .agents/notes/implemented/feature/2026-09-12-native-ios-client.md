# Agent Note: native iOS client

Status: implemented

English | [中文](2026-09-12-native-ios-client.zh.md)

## Problem

The browser frontend can control a dsh Host remotely, but a personal iPhone client needs native navigation, touch behavior, safe-area layout, and efficient incremental updates without moving the agent runtime or repository onto the phone. A second mobile backend would duplicate Session authority and make the phone responsible for infrastructure that already belongs to the development machine.

## Decision

Whale Girl (`鲸鱼娘`) is a native SwiftUI application under `apps/ios`. It is only a frontend: the dsh Web profile remains the sole Host for model calls, tools, working directories, Session persistence, and authentication.

The app consumes the existing Typert Gateway wire operations directly. HTTP carries `session/list`, `session/create`, `session/prompt`, and `session/cancel`; the Gateway's authenticated `/api/remote.stream` HTTP NDJSON carrier carries `session/follow`. Both the native HTTP carrier and browser WebSocket emit the same Gateway frames from the same dispatcher, but the iOS app fails with Host-upgrade guidance when the HTTP carrier is absent instead of entering a WebSocket retry loop known to stall on the target iPhone tunnel path. Session selection is local navigation, while opening the follow stream performs the existing cold read and Host promotion. The app does not add a parallel REST API or mobile projection service.

The connection screen accepts the authenticated URL emitted by the Web application. URLSession exchanges the one-time query token for the existing signed browser cookie, strips the token before persisting the Host URL, and reuses the cookie for HTTP and WebSocket traffic. Production builds require HTTPS. A tunnel or reverse proxy terminates TLS and forwards to the Web profile's loopback listener.

`ConversationProjection` folds the opening Session snapshot, older history pages, and subsequent events into Turn-oriented mobile state. Human messages and assistant text render as bubbles. A long press exposes the system context menu with whole-message Copy and Select Text; Select Text opens a native selectable text view so the user can copy an exact range. Reasoning, tool arguments, tool results, streaming state, cancellation, and failures stay inside the owning Turn's expandable process panel. Transient assistant chunks update the active Turn in place, and a durable assistant event replaces its temporary message.

Each working-directory group initially renders its five most recently updated Sessions. A group-local disclosure reveals or hides the remaining Sessions without changing Host order or mutating Workspace state.

Every settled user and assistant bubble uses MarkdownUI's GitHub-flavored parser and renderer. The app caches parsed documents by message identity and source, gives code blocks an owned monospaced surface, and keeps wide tables horizontally scrollable inside the bubble. The raw source remains the value copied by whole-message and range-selection actions.

The foreground owns the live follower. Background entry cancels it to quiescence without cancelling the Agent; foreground entry opens a new `session/follow` generation and keeps the previous transcript visible until its authoritative snapshot arrives. Connection loss, timeout, and POSIX connection abort are transient recovery states: they retry under bounded exponential backoff and drive an animated, non-modal status. Authentication, protocol, and business failures stop the loop and provide an actionable Retry or connection-setting instruction.

The last selected Session id and the clean Host URL survive process termination. Force quit has no required cleanup path; the operating system closes the client transport, the Host Agent remains independent, and the next process restores through a fresh list and follow snapshot.

Early-development observability is shipped source. `WhaleDiagnostics` owns privacy-safe OSLog categories for app, lifecycle, transport, Session, and interaction events; Debug builds also mirror recovery-critical state to stdout for `devicectl --console` and disable the idle timer. Diagnostics record endpoint names, counts, generation numbers, error domains, and codes, but never Host URLs, cookies, Session ids, working directories, or message content.

## Alternatives considered

**Embed the existing Web application in a WKWebView.** This would reuse browser rendering but retain mobile browser layout and interaction costs, provide a weaker native navigation model, and make the application a wrapper rather than an iOS frontend.

**Add a mobile-specific Host API.** A tailored REST and WebSocket projection resembles the Eva-Link architecture, but dsh already exposes typed unary and stream operations with authentication, cold history, and reconnect snapshots. A second API would duplicate authorization, lifecycle, event interpretation, and compatibility work.

**Run dsh on iOS.** This would move Node, tools, source access, credentials, and process execution onto a restricted device. It conflicts with the product reason for the client: the development machine remains the execution environment.

## Consequences

The phone can navigate Sessions from different working directories, send and stop work, and follow text, reasoning, and tool activity without owning project files or model credentials. Disconnecting the app does not stop the Host Session.

The native projection intentionally covers the mobile conversation subset rather than loading browser plugins. New Session event types remain ignored until the app gives them a native presentation, and browser-only capabilities such as approvals, files, settings, and plugin-contributed cards are unavailable. The app must track Gateway and Session wire changes in the same repository, while the existing Host protocol remains the only transport authority. Suspending the follower means background delivery is not promised; the reconnect snapshot is the recovery authority.
