# PrismaX

A native macOS app for managing Prisma workflows across multiple projects and environments. Built with SwiftUI + SwiftData, with secrets stored in the macOS Keychain.

## Why

The Prisma CLI has **no `--env-file` flag** (open request since 2020). Switching between local/staging/production means swapping `.env` files or wrapping every command in `dotenv-cli`. PrismaX solves this natively: macOS's `Process` API accepts a full environment dictionary, so PrismaX pulls the selected environment's secrets from the Keychain and injects them directly into the spawned prisma process. `DATABASE_URL` is correct every time — never written to disk in plaintext.

## Features

- **Multiple projects** — add a project by name + folder; package manager (npm/pnpm/yarn/bun) and `schema.prisma` location are auto-detected.
- **Environments per project** — define development / staging / production with their own variables. Values live in the macOS Keychain; only keys are stored in the app's database.
- **Saved commands** — a sensible default set (`migrate deploy`, `db push`, `studio`, `generate`, etc.) is created per project. Run any with one click against the selected environment.
- **Guardrails (hybrid model)** — per-environment overrides: *allow* (run immediately), *confirm* (require explicit confirmation), or *block* (disabled). Stop `migrate dev` from ever running on production.
- **Live terminal output** — stdout/stderr streamed line-by-line with cancel support.
- **History & rerun** — every run is persisted (output, exit code, duration).
- **.env import** — paste an existing `.env` to onboard an environment in seconds.

## Build

The easiest way is the included distribution script, which renders the icon,
generates the Xcode project, builds a Release `.app`, and packages a `.dmg`
into `./dist`:

```bash
./build.sh                 # → dist/PrismaX.app + dist/PrismaX-1.0.dmg
./build.sh --no-dmg        # just the .app
./build.sh --clean         # rebuild from scratch
```

This produces an **ad-hoc signed, un-notarized** build suitable for sharing
without an Apple Developer account. Recipients will see a Gatekeeper warning on
first launch — to open it: **right-click the app → Open → Open** (or *System
Settings → Privacy & Security → Open Anyway*).

Requirements for building:

- macOS 15 (Sequoia) or later
- Xcode 16+ (or the Command-Line Tools) — provides `xcodebuild` and `swift`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- Node.js + a package manager (npm/pnpm/yarn/bun) for the projects you manage

### Manual build

```bash
# Generate the Xcode project (requires xcodegen)
xcodegen generate

# Build from the command line
xcodebuild -project PrismaX.xcodeproj -scheme PrismaX -configuration Release build

# Or open in Xcode
open PrismaX.xcodeproj
```

The built app lands in `~/Library/Developer/Xcode/DerivedData/...`. Run it from
there, or copy it to `/Applications`.

### App icon

Place a high-resolution icon (1024×1024 PNG) at `icons/1024.png`. The build script
automatically generates all required sizes from this source. To regenerate icons:

```bash
./scripts/generate_icons.sh icons/1024.png
```

This writes all sizes into `PrismaX/Resources/Assets.xcassets/AppIcon.appiconset`,
which the build picks up via the asset catalog. The build script runs this
automatically unless you use `--no-icon`.

## Architecture

```
PrismaX/
├── Models/         SwiftData @Model classes (Project, Environment, Command, …)
├── Services/       RunService, EnvironmentResolver, TerminalManager, KeychainService, …
└── Views/          SwiftUI views (NavigationSplitView shell + tabs)
```

### Core mechanism

Commands run inside an **integrated terminal** (a real PTY shell rendered with
xterm.js), so they behave exactly like your own shell — interactive prompts,
colors, and `prisma studio` all work. The run flow:

1. `RunService.run()` builds the invocation via `PrismaCommandBuilder`, which
   resolves the prisma executable from the detected package manager
   (`pnpm exec prisma`, `yarn prisma`, `bunx prisma`, `npx prisma`) and
   appends `--schema` (relativized to the command dir) when needed.
2. `TerminalManager` dispatches it into the project's shell. Before the shell
   starts, `EnvironmentResolver` overlays the selected environment's secrets —
   read from the macOS Keychain (and an optional `.env` file) — onto the
   process environment. `DATABASE_URL` is correct every time.
3. Switching the active environment restarts the shell so the new env's
   secrets take effect.
4. Every dispatch is recorded as a `RunRecord` (History), so runs can be
   inspected and re-dispatched later.

Secrets never touch disk in plaintext.

## Roadmap

- [x] v1 core: projects, environments, saved commands, live output, guardrails, history
- [ ] DB backups (`pg_dump` / `mysqldump`) with restore and in-app scheduling
- [ ] Live schema introspection (`schema.prisma` parser + `prisma migrate status`)
- [ ] Background scheduled backups via a LaunchAgent
- [ ] Code signing & Sparkle auto-update for distribution

## License

Copyright (c) 2026 PrismaX. All rights reserved.
