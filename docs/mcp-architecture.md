# Marsa (Cybertea) MCP Service — Architecture & Security Model

This document defines the architecture and security model for adding a **Model Context Protocol (MCP)** service to Marsa (`CYBERTEA-1`), enabling AI agents to connect to Marsa and use stored SSH/SFTP credentials safely.

---

## 1. Core Principle: Credential Brokering, Never Secret Exposure

AI agents **must never receive raw credentials** (passwords, private keys, passphrases, or cloud sync tokens). Instead, Marsa acts as a **local credential broker**:

1. Agents discover **metadata** (host IDs, labels, addresses, usernames, tags, groups, snippet names) from unlocked vaults.
2. Agents invoke **brokered tools** (e.g., `ssh_exec`, `sftp_list`, `sftp_read`) referencing a `hostId`.
3. Marsa resolves `vault.data.credentialsFor(host)` internally, opens the SSH/SFTP connection via `connect(vault, host, prompter)` in `lib/ssh/connector.dart`, executes the operation, and returns only the sanitized result.

---

## 2. High-Level Architecture

```text
┌────────────────────────┐         JSON-RPC 2.0 (MCP)         ┌─────────────────────────────────┐
│  AI Agent / IDE        │ ◄────────────────────────────────► │  Marsa App (lib/mcp/)           │
│  (Antigravity, Cursor, │   Loopback HTTP/SSE (127.0.0.1)    │  - McpServer & Transport        │
│   Claude Desktop, etc) │   or stdio-to-loopback bridge      │  - Auth & Token Policy Engine   │
└────────────────────────┘                                    │  - Tool Router & Redactor       │
                                                              │  - Audit Logger                 │
                                                              └──────────────┬──────────────────┘
                                                                             │
                                         ┌───────────────────────────────────┴───────────────────────────────────┐
                                         ▼                                                                       ▼
                        ┌─────────────────────────────────┐                                     ┌─────────────────────────────────┐
                        │  Vault Layer (lib/core/)        │                                     │  SSH / SFTP Layer (lib/ssh/)    │
                        │  - VaultRegistry / VaultSession │                                     │  - connect() / Connection       │
                        │  - Host, Identity, Snippet      │                                     │  - RemoteFiles (SFTP)           │
                        │  - KnownHost                    │                                     │  - DeviceKeys (~/.ssh)          │
                        └─────────────────────────────────┘                                     └─────────────────────────────────┘
```

### Planned Module Layout (`lib/mcp/`)
- `lib/mcp/mcp_server.dart` — JSON-RPC 2.0 dispatcher, MCP lifecycle (`initialize`, `notifications/initialized`, `ping`), `tools/list`, `tools/call`, `resources/list`, `resources/read`.
- `lib/mcp/transport_http.dart` — Loopback-only (`127.0.0.1`) Streamable HTTP / SSE server with bearer-token middleware.
- `lib/mcp/auth.dart` — Per-agent token issuance, hashing, scope evaluation (vaults, hosts, tool tiers), and revocation.
- `lib/mcp/prompter.dart` — `McpPrompter implements Prompter` (`lib/ssh/connector.dart`) to route host-key verification and interactive prompts safely.
- `lib/mcp/tools.dart` — Discovery, `ssh_exec`, and `sftp_*` tool handlers with secret stripping and output/size limits.
- `lib/mcp/audit.dart` — Structured local audit log and live session state notifications for the UI.

---

## 3. Transport & Vault Lifecycle

### Transports
1. **Primary — Loopback HTTP / SSE (`127.0.0.1:<port>`)**:
   - Runs inside the Marsa desktop process while the MCP service is enabled.
   - Strictly bound to `127.0.0.1` (never `0.0.0.0`) with `Host` header validation to prevent DNS rebinding.
2. **Optional — `stdio` Bridge**:
   - A lightweight CLI entrypoint that speaks MCP over `stdin`/`stdout` and forwards requests to the running Marsa loopback endpoint using a configured bearer token.

### Vault Unlock Lifecycle
- **Unlocked Vaults Only**: The MCP server only sees `VaultSession` instances currently unlocked in memory. Locked vaults are invisible and inaccessible.
- **Auto-Disconnect on Lock**: When a `VaultSession` is locked or closed, all active agent connections and in-flight SSH/SFTP `Connection`s tied to that vault are immediately closed, and subsequent tool calls for that vault return a structured `VAULT_LOCKED` error.
- **No Sync of MCP State**: Agent tokens, permissions, and audit logs are **device-local** (stored alongside local app settings / OS keychain via `flutter_secure_storage`), never written into the synced `VaultData` file.

---

## 4. Authentication, Scopes & User Consent

### Per-Agent Bearer Tokens
- Each authorized AI client receives a unique, high-entropy bearer token (stored hashed on disk; shown once at creation/pairing).
- Tokens are tied to an **Agent Profile** with explicit scopes:
  - **Allowed Vaults**: All unlocked vaults or specific `vaultId`s.
  - **Allowed Hosts**: All hosts, specific `hostId`s, or hosts matching specific `group` / `tags`.
  - **Permission Tier**:
    1. `discover` — Read-only metadata (`list_hosts`, `get_host`, `list_identities`, `list_snippets`).
    2. `sftp_read` — `discover` + `sftp_list`, `sftp_stat`, `sftp_read`.
    3. `sftp_write` — `sftp_read` + `sftp_write`.
    4. `ssh_exec` — Execute commands via `ssh_exec` (can be gated by command allowlist/denylist or per-call UI confirmation).

### Consent & Revocation
- **Interactive Approval (Optional/Default for sensitive ops)**: Marsa can prompt the user with an in-app approval dialog showing the agent name, target host, and command/path before executing.
- **Instant Revocation**: Revoking an agent token in Settings immediately rejects future requests and tears down any active SSE/SSH sessions for that agent.

---

## 5. Host Key Verification (`McpPrompter`)

`connect()` in `lib/ssh/connector.dart` requires a `Prompter`:
- **Pinned Host (`knownHosts` match)**: Succeeds automatically.
- **Unknown or Changed Host Key**:
  - If Marsa is interactive and the user approves via an in-app prompt, `McpPrompter` returns `true` and pins the key.
  - In unattended/headless mode (or if the user declines), `McpPrompter.confirmNewHost` and `confirmChangedHost` return `false` to prevent silent MITM acceptance.
- **Secret / Interactive Auth Prompts**: `askSecret` / `askInteractive` never ask the AI agent for passwords; they either prompt the local user in Marsa or fail cleanly if unattended.

---

## 6. Tool Surface & Guardrails

### Discovery Tools (Metadata Only)
- `list_hosts` / `get_host`: Returns `id`, `label`, `address`, `port`, `username`, `group`, `tags`, `jumpHostId`, `useDeviceKeys`, and `authType` (`password` | `key` | `identity` | `deviceKeys`). **Never** returns `password` or `privateKey`.
- `list_identities`: Returns `id`, `label`, `username`, `hasKey`, `hasPassword`.
- `list_snippets`: Returns `id`, `label`, `command`.

### Execution Tools (Brokered)
- `ssh_exec`: Executes a single non-interactive command on `hostId` with configurable timeout (e.g., default 30s, max 120s) and stdout/stderr byte cap (e.g., 64 KiB) to protect agent context and memory.
- `sftp_list`, `sftp_stat`, `sftp_read`, `sftp_write`: Operates via `RemoteFiles` (`lib/ssh/files.dart`) with max read/write size limits and path normalization.

---

## 7. Audit Logging

Every MCP request (`tools/call`, `resources/read`, auth failures) appends a local structured record:
- `timestamp`, `agentId`, `agentName`, `vaultId`, `hostId`
- `toolName`, `redactedArgs` (e.g., file contents or sensitive flags redacted)
- `status` (`allowed`, `denied`, `error`, `ok`), `durationMs`, `exitCode` (for `ssh_exec`)

---

## 8. Implementation Roadmap (Plane Tasks)
- `CYBERTEA-2`: Core MCP Protocol Server & Transport Layer
- `CYBERTEA-3`: Agent Authentication, Scoped Tokens & Consent Flow
- `CYBERTEA-4`: Host, Group & Identity Discovery Tools/Resources
- `CYBERTEA-5`: Brokered SSH Command Execution Tool (`ssh_exec`)
- `CYBERTEA-6`: Brokered SFTP Read/Write Tools
- `CYBERTEA-7`: Audit Logging & Live Agent Activity Tracking
- `CYBERTEA-8`: MCP Settings & Agent Access Management UI
- `CYBERTEA-9`: Integration Tests & Agent Connection Documentation
