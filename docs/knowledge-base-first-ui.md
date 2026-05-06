# Knowledge-Base-First UI Refactor

## Why the current UI is no longer enough

The app started as a compact dashboard for:

- boot/sync visibility
- task-phase tracking
- shared-memory inspection
- chat export

That was the right shape when the product's main value was observability.

It is no longer the right center of gravity if the product is shifting toward:

- Obsidian vault normalization
- maintained wiki generation
- knowledge-base health
- long-term human-readable synthesis

In other words:

- the current app is still dashboard-first
- the next app should become knowledge-base-first

The dashboard should remain important, but it should become a supporting surface rather than the main story.

## The current scope of the new wiki actions

This needs to be explicit because the current controls are easy to over-read.

### `Normalize Vault Layout`

Today it does:

- create canonical folder scaffolding such as `00 Raw Sources`, `10 Wiki`, `20 Queries and Reports`, and `90 System`
- generate `obsidian-wiki-schema.md`
- generate `index.md`
- generate `log.md`
- create project wiki directories

Today it does **not**:

- move existing `NotebookLM`, `Notion`, or legacy top-level folders automatically
- rewrite all existing vault content
- infer a full migration plan from every current file in the vault

### `Build Current Project Wiki`

Today it does:

- compile the **current workspace** into maintained project wiki pages
- write `Overview.md`
- write `Current Status.md`
- write `Architecture.md`
- write `Decisions.md`
- write `Open Questions.md`
- write `Sources.md`

Today it does **not**:

- rebuild all project trees across the whole vault
- process every imported source automatically
- recompile unrelated projects unless they are selected and built

So the current MVP is:

- `raw source aware`
- `current-workspace wiki compiler`
- `not yet a full vault migration engine`

That is a good first slice, but the UI should communicate that much more clearly.

## Product direction

The app should now be framed as:

`a clean knowledge-base maintainer for agent-built Obsidian wikis`

and only secondarily as:

`a dashboard for sync and memory observability`

This matters because it changes how the user should move through the product.

The main user questions are no longer:

- what phase is my task in?
- did sync succeed?

They become:

- is my vault standardized?
- what raw sources have arrived?
- what wiki pages were compiled?
- what parts of the knowledge base are stale or missing?

## New interaction model

The app should be reorganized around four top-level modes.

### 1. Library

This becomes the new home screen.

Its job:

- show vault readiness
- show wiki readiness
- show how many projects have maintained wiki pages
- show how many raw-source providers exist
- expose the primary actions

Primary actions:

- `Normalize Vault`
- `Build Current Project Wiki`
- `Build All Ready Projects`
- `Open Vault in Finder`
- `Open Wiki Index`

This page should feel calm and structured, not like a monitoring board.

### 2. Sources

This is where raw material enters the system.

Its job:

- show the raw-source layout
- show agent chat exports
- show external imports such as NotebookLM and Notion
- show which sources are normalized versus legacy
- show what has not yet been compiled into wiki pages

Primary actions:

- `Export Current Workspace Chats`
- `Export All Known Workspaces`
- `Mark as External Import`
- `Queue for Wiki Compile`

This page should make the distinction between raw sources and maintained wiki outputs obvious.

### 3. Wiki

This is the primary maintained layer.

Its job:

- show projects with wiki coverage
- show whether `Overview`, `Current Status`, `Architecture`, `Decisions`, `Open Questions`, and `Sources` are present
- preview generated page content
- show last build time and source coverage

Primary actions:

- `Build Current Project Wiki`
- `Refresh Status`
- `Refresh Architecture`
- `Rebuild Index`
- `Open in Obsidian`

This page should look more like a clean library manager than a terminal dashboard.

### 4. Observe

This is where the existing dashboard belongs.

Its job:

- Session
- Phase
- Sync Delta
- Question Profile
- Project Memory
- Update Log
- Recent Activity

This surface still matters, but it becomes:

- operational visibility
- not the main product promise

## Design principles for the refactor

### 1. Quiet by default

The UI should become simpler, not busier.

That means:

- fewer equal-weight cards on the first screen
- clearer primary actions
- more white space and hierarchy
- less “everything is a panel”

### 2. Build around transformations

The important user actions are transformations:

- raw source -> normalized source
- normalized source -> wiki page
- wiki page -> refreshed knowledge

The UI should foreground these flows instead of foregrounding diagnostics alone.

### 3. Keep networked knowledge understandable

The product exists to make networked knowledge simpler.

So we should avoid the common trap of knowledge software:

- too many panes
- too many trees
- too many tiny controls
- too much graph theater

Instead:

- show the structure in a disciplined, page-oriented way
- use the graph idea implicitly through links and relationships
- reserve advanced diagnostics for secondary views

### 4. Separate current state from durable state

Users should never confuse:

- what is happening in the current session
- what has already been compiled into durable wiki knowledge

That distinction should appear everywhere in the language:

- `Observe` for live state
- `Wiki` for durable state
- `Sources` for incoming raw material

## Recommended first concrete UI refactor

Before doing a full redesign, the next practical step should be:

### Step 1

Add a top-level mode switch:

- `Library`
- `Sources`
- `Wiki`
- `Observe`

### Step 2

Make `Library` the default landing view instead of the current dashboard scroll.

### Step 3

Move the current card stack into `Observe`.

### Step 4

Create a small `Wiki` view with:

- current project wiki status
- generated page list
- last build timestamp
- open buttons for `index.md`, `log.md`, and the current project pages

### Step 5

Create a small `Sources` view with:

- configured raw chat directory
- known source roots
- export actions
- migration warnings for legacy top-level folders

This would already shift the product story in the right direction without making the app complex.

## What should wait until later

These are useful, but not the next slice:

- full graph visualization
- automatic migration of every legacy folder
- embedded note editor
- cross-project full-text search UI
- interactive knowledge graphs
- large control-center-style monitoring surfaces

The main win should come from:

- standardization
- compilation
- calm navigation

not from adding more widgets.

## Recommended immediate wording change

The product's public description should gradually move from:

- `dashboard`

toward:

- `knowledge base maintainer`
- `wiki compiler`
- `memory console`

while still keeping the existing app bundle stable for now.

That way the software's promise better matches what it is becoming.
