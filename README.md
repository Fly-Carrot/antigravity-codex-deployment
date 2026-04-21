# Shared Fabric Dashboard

Shared Fabric Dashboard is a setup-first deployment repo for a shared agent fabric built around Codex, Gemini, canonical memory lanes, exact six-stage task phases, and a macOS desktop dashboard.

This repository is designed to help you do three things well:

1. bootstrap a reusable shared-fabric storage root on a new machine
2. enable any workspace with a thin `AGENTS.md` bridge plus VSCode task entrypoints
3. observe task state, sync deltas, and project memory through terminal and desktop dashboards

## What This Repo Contains

This repo is not the live shared-fabric state itself. It is the portable control plane for standing that system up elsewhere.

It includes:

- installation and doctor scripts
- shared-fabric config templates
- sync and postflight tooling
- rich memory expansion and backfill tooling
- a compact terminal dashboard
- a native macOS desktop dashboard app
- workspace bootstrap entrypoints for Codex and Gemini

## Core Product Shape

The current product direction is setup-first.

That means the main entrypoints are:

- `install/bootstrap_shared_fabric.py`
  Creates the shared storage root, local path config, framework skeleton, and doctor-checked install chain.
- `install/bootstrap_vscode_workspace.py`
  Enables a workspace by generating `AGENTS.md`, `.vscode/tasks.json`, and the Gemini compatibility bridge.
- `tools/compact_dashboard/`
  Terminal snapshot and monitoring surface.
- `tools/compact_dashboard_desktop/`
  macOS desktop app with workspace switching, settings, sync drill-down, project memory browsing, and setup assistance.

## Major Capabilities

### 1. Shared-Fabric Storage Bootstrap

Use the storage bootstrap to stand up a new canonical shared-fabric root:

```bash
python3 install/bootstrap_shared_fabric.py
```

For non-interactive setup:

```bash
python3 install/bootstrap_shared_fabric.py \
  --non-interactive \
  --global-root /path/to/global-agent-fabric \
  --desktop-root /path/to/Desktop
```

This bootstrap:

- creates the shared directory skeleton
- renders local config files
- installs the framework snapshot into the chosen global root
- prepares Gemini/Codex-compatible paths
- runs the doctor chain after installation

### 2. Workspace-First VSCode Enablement

Enable a workspace for shared-fabric usage with:

```bash
python3 install/bootstrap_vscode_workspace.py \
  --workspace /path/to/workspace \
  --global-root /path/to/global-agent-fabric \
  --runtimes both
```

This writes:

- project-root `AGENTS.md`
- `.vscode/tasks.json`
- Gemini `settings.json` compatibility updates when Gemini is included

The generated VSCode tasks expose:

- `Shared Fabric: Boot Current Workspace`
- `Shared Fabric: Sync Current Workspace`
- `Shared Fabric: Postflight Sync`
- `Shared Fabric: Open Global Root`
- `Shared Fabric: Rebuild Workspace Entry`

The integration model is intentionally workspace-first rather than a custom VSCode extension. The durable source of truth stays in:

- project `AGENTS.md`
- canonical shared-fabric scripts
- shared memory lane files

### 3. Exact Task Observability

The shared fabric supports exact six-stage task tracking:

- `route`
- `plan`
- `review`
- `dispatch`
- `execute`
- `report`

These phases are written through the canonical logger and can be observed from the dashboard surfaces.

### 4. Rich Memory Architecture

The shared fabric keeps one canonical memory family, expanded into rich structured bundles across:

- `Decision`
- `Handoff`
- `Mem`
- `Loop`
- `Learn`
- `Receipt`

The desktop dashboard now exposes project memory as a real browser rather than only a latest-sync audit surface.

### 5. macOS Dashboard App

The desktop app includes:

- app menu, file menu, view menu, and standard window behavior
- workspace switching with auto-follow and pinned modes
- settings persistence through `UserDefaults`
- project memory browsing with drill-down details
- sync delta inspection with clickable records
- setup assistant for storage-root bootstrap and workspace bootstrap

## Repository Layout

```text
antigravity-codex-deployment/
  README.md
  docs/
    releases/
  fabric/
    memory/
    mcp/
    scripts/
      sync/
    sync/
  install/
  manifests/
  tests/
  tools/
    compact_dashboard/
    compact_dashboard_desktop/
```

## Quick Start

### 1. Bootstrap the shared storage root

```bash
python3 install/bootstrap_shared_fabric.py
```

### 2. Enable a workspace

```bash
python3 install/bootstrap_vscode_workspace.py \
  --workspace /path/to/workspace \
  --global-root /path/to/global-agent-fabric \
  --runtimes both
```

### 3. Run dashboard tooling

Terminal dashboard docs:

- [tools/compact_dashboard/README.md](/Users/david_chen/Desktop/antigravity-codex-deployment/tools/compact_dashboard/README.md)

Desktop app source and build entrypoint:

- [FloatingDashboard.swift](/Users/david_chen/Desktop/antigravity-codex-deployment/tools/compact_dashboard_desktop/FloatingDashboard.swift)
- [build_dashboard_app.sh](/Users/david_chen/Desktop/antigravity-codex-deployment/tools/compact_dashboard_desktop/build_dashboard_app.sh)

## Release Notes

- [v2.0.0](/Users/david_chen/Desktop/antigravity-codex-deployment/docs/releases/v2.0.0.md)
- [v3.0.0](/Users/david_chen/Desktop/antigravity-codex-deployment/docs/releases/v3.0.0.md)

## Status

The repository now represents the setup-first Shared Fabric Dashboard baseline:

- canonical shared-fabric sync and memory tooling
- workspace-first Codex/Gemini enablement
- rich project-memory browsing
- setup assistant in the macOS app
- static packaged app icon pipeline

For public publishing, this repo should be treated as the product/deployment snapshot, not as a live export of local secrets or machine-private memory state.
