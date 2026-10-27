# Codex

After installing Drifted (see AGENTS.md), add this to `~/.codex/config.toml`. **Drifted → Connect your AI…**
in the menu bar shows the same details as a prompt you can paste into Codex.

```toml
[mcp_servers.drifted]
command = "/Applications/Drifted.app/Contents/MacOS/drifted-mcp"
```

Any other MCP client works the same way: run `drifted-mcp` over stdio. It talks to the host at
`http://localhost:8765` (override with `DRIFTED_URL`) and reads the token from
`~/Library/Application Support/Drifted/token` (override with `DRIFTED_TOKEN_FILE` or `DRIFTED_TOKEN`).
