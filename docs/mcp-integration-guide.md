# MCP Integration Guide

Fabric ships with **no enabled MCP servers by default**.

That is deliberate. MCP servers can run local commands, reach third-party
services, or read sensitive files. A public starter should never silently enable
network tools for a new user.

## Recommended model

1. Keep Fabric's public registry empty until you decide what to trust.
2. Install MCP servers in your own runtime environment.
3. Store secrets in environment variables or an ignored local file.
4. Mirror only safe server metadata into your private shared-fabric registry.
5. Re-run your preflight/sync step so agents see the updated tool registry.

## Strongly recommended optional integrations

- **MemPalace** for detailed process memory and trial-and-error records.
- **Maestro** for explicit subagent orchestration and dispatch discipline.

These are recommended extensions, not hard dependencies. The fixed Fabric App
workflow still works without them.

## Example private registry shape

Keep examples like this in a private file, not in the committed public starter:

```yaml
version: 1
servers:
  - id: "example-docs"
    enabled: false
    command: "/path/to/private/mcp-server"
    args: []
    env_refs:
      - "EXAMPLE_API_KEY"
```

Turn `enabled` on only after you understand the server's permissions, network
behavior, and secret requirements.
