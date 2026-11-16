# Connecting AI Agents to Marsa via MCP

Marsa includes a local **Model Context Protocol (MCP)** service that lets AI agents (such as Antigravity, Claude Desktop, or Cursor) discover your saved hosts and run brokered SSH/SFTP operations using your vault credentials—**without ever exposing raw passwords or private keys to the AI agent**.

---

## 1. Enable the MCP Service

1. Open Marsa and unlock a vault.
2. Go to **Settings → AI Agents (MCP)**.
3. Toggle **MCP service** on (default loopback endpoint: `http://127.0.0.1:47832/mcp`).
4. Click **New token**, choose an agent name, permission tier, and whether to require interactive approval per execution.
5. Copy the generated bearer token or click **Copy MCP config**.

> **Note:** The MCP server only sees **currently unlocked** vaults. Locking a vault immediately disconnects active agent sessions.

---

## 2. Client Configuration

Paste the copied configuration into your AI client's MCP configuration file:

```json
{
  "mcpServers": {
    "marsa": {
      "url": "http://127.0.0.1:47832/mcp",
      "headers": {
        "Authorization": "Bearer <YOUR_MARSA_AGENT_TOKEN>"
      }
    }
  }
}
```

---

## 3. Permission Tiers

| Tier | Capabilities |
| :--- | :--- |
| **Discovery only** (`discover`) | `list_hosts`, `get_host`, `list_identities`, `list_snippets`, and MCP resources (`marsa://hosts`, `marsa://snippets`). Metadata only; all secrets are stripped. |
| **Discovery + SFTP read** (`sftpRead`) | Adds `sftp_list`, `sftp_stat`, `sftp_read`. |
| **Discovery + SFTP read/write** (`sftpWrite`) | Adds `sftp_write`. |
| **Full (SSH exec + SFTP)** (`sshExec`) | Adds `ssh_exec` for non-interactive command execution. |

---

## 4. Security Model

- **Loopback-only binding:** The server binds strictly to `127.0.0.1` and validates the `Host` header to block DNS-rebinding attacks.
- **No secret leakage:** Passwords, private keys, and passphrases are never returned by any tool or resource.
- **Per-call approval:** Tokens with *Require approval per execution* prompt you in Marsa before executing `ssh_exec` or SFTP tools.
- **Audit log:** Every tool call is logged locally with timestamp, agent name, target host, status, and duration. View or export it from **Settings → AI Agents (MCP) → Audit log**.
