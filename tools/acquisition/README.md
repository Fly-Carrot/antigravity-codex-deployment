# Optional Acquisition Utilities

Fabric's core app is a knowledge processing workbench: it reads existing source,
wiki, graph, and shared-fabric artifacts, then helps maintain a human-readable
LLM-wiki layer.

This folder is intentionally separate from the core dashboard pipeline. Tools
here may export or convert local agent chat history into files that an external
pipeline can later place into a raw-source lane. They are personal utilities, not
Fabric's public product identity.

Safety notes:

- Run these utilities only against data you own.
- Review outputs before moving them into a public repository or Obsidian vault.
- Keep API keys, cookies, private runtime databases, and browser profiles out of
  exported artifacts.
- Prefer writing acquisition outputs to a private staging directory, then let
  Fabric process sanitized inputs.
