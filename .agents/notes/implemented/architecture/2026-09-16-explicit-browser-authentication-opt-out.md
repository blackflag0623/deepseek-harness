# Agent Note: explicit browser-authentication opt-out

Status: implemented

English | [中文](2026-09-16-explicit-browser-authentication-opt-out.zh.md)

## Problem

The Web Host's uniform browser authentication protects its tool-capable API, but some operators place the loopback server behind a separately authenticated transport and do not want a second token exchange. Inferring that trust from `trustedHosts`, forwarding headers, or a non-loopback authority would silently turn routing configuration into identity.

## Decision

`dsh-client-connection` exposes `browserAuthentication: required | disabled`, defaulting to `required`. The `disabled` value is an explicit deployment decision: index requests bypass launch-token exchange, printed application URLs contain no token, and API requests that pass the existing Host/Origin checks reach dispatch without a browser cookie. Host/Origin validation remains mandatory and continues returning 403 for rejected requests.

The setting belongs to the Connection row rather than the Web application or server. Connection owns authentication for index authorization, HTTP Remote calls, exact Fetch routes, and WebSocket upgrades, so one value changes every carrier entry consistently. The shipped Web bundle retains `required`; a profile or later bundle layer must opt out by replacing the Connection config.

## Alternatives considered

**Disable authentication whenever `trustedHosts` is non-empty.** Trusted authorities prevent DNS rebinding and cross-site requests but do not identify callers. Coupling the two would make an ordinary deployment hostname silently grant process authority.

**Add a `--no-auth` application flag.** A one-invocation flag is easy to overlook in durable deployments and makes the Web application mutate policy owned by Connection. Profile configuration keeps the high-impact choice reviewable beside the accepted authorities.

**Trust forwarding headers.** The loopback server has no current proxy-identity contract or trusted-proxy list. Accepting headers would let a direct caller assert the missing identity.

## Consequences

Disabling browser authentication grants every caller that can reach an accepted authority the complete tool-capable Host API. The operator owns external authentication, transport confidentiality, and access revocation; DSH cannot identify callers or issue per-browser sessions in this mode. The opt-out does not enable non-loopback binding, weaken Host/Origin checks, or change the default.

This decision partially supersedes the unconditional-authentication requirement in [browser launch-token authentication](2026-08-24-browser-token-authentication.md). That decision remains active authority for `required` mode, cookie and launch-token semantics, and the security capability being waived. No active Agent Note is archived because both modes and their rationale remain current.
