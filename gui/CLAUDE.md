# Prosca GUI

Tauri 2 desktop app providing a graphical interface for the Prosca AI agent. When developing this project use the tauri MCP server to start the app and read error messages from the app console

## Stack

- **Frontend:** React 19 + TypeScript + Vite
- **Backend:** Tauri 2 (Rust)
- **Communication:** Sidecar — launches `julia --project=. json_io.jl` as a child process, communicates via stdin/stdout JSON lines prefixed with `PROSCA:`

## Project Structure

```
gui/
├── src/                        # React frontend
│   ├── main.tsx                # Entry point
│   ├── App.tsx                 # Provider tree + page routing
│   ├── contexts/               # React contexts (state management)
│   │   ├── SidecarContext.tsx   # Tauri IPC bridge (invoke/listen)
│   │   ├── ChatContext.tsx      # Message state + reducer
│   │   ├── ConversationContext.tsx
│   │   └── SettingsContext.tsx   # Config sync + theme
│   ├── pages/                  # Top-level page components
│   │   ├── ChatPage.tsx
│   │   ├── HomePage.tsx
│   │   ├── SkillsPage.tsx
│   │   ├── McpToolsPage.tsx
│   │   ├── RoutinesPage.tsx    # Placeholder (needs backend scheduler)
│   │   └── SettingsPage.tsx
│   ├── components/
│   │   ├── layout/             # Sidebar, Header, InputArea
│   │   ├── messages/           # MessageList, MessageItem, ToolApprovalCard, WorkingIndicator
│   │   ├── tool-views/         # GenericToolView (renders tool results)
│   │   ├── skills/             # SkillCard
│   │   └── mcp-tools/          # McpServerCard
│   ├── types/                  # TypeScript type definitions
│   │   ├── sidecar.ts          # SidecarEvent union, McpServerInfo, SkillInfo
│   │   ├── message.ts          # ChatMessage union type
│   │   └── conversation.ts     # Conversation interface
│   └── styles/                 # CSS (no preprocessor)
│       ├── tokens.css          # Design tokens (CSS custom properties, light/dark)
│       ├── base.css            # Reset + app-level layout
│       ├── layout.css          # Sidebar styles
│       └── components.css      # All component styles
├── src-tauri/                  # Rust backend
│   ├── src/
│   │   ├── main.rs             # Entry point
│   │   ├── lib.rs              # Tauri commands (start/send/stop_sidecar), prosca_dir resolution
│   │   └── sidecar.rs          # SidecarProcess: spawn Julia, filter PROSCA: lines, emit events
│   ├── Cargo.toml
│   └── tauri.conf.json
├── package.json
├── tsconfig.json
└── vite.config.ts
```

## Commands

```bash
npm run dev          # Vite dev server (frontend only, no Tauri)
npm run build        # TypeScript check + Vite production build
npm run tauri dev    # Full Tauri dev mode (frontend + Rust + sidecar)
npm run tauri build  # Production build (.app / .dmg)
npx tsc --noEmit     # TypeScript type check only
cargo build --manifest-path src-tauri/Cargo.toml  # Rust build only
```

## Architecture

### Sidecar Protocol

The Rust backend spawns `julia --project=. json_io.jl` in the parent Prosca directory. Communication uses newline-delimited JSON on stdin/stdout.

- **Stdout lines prefixed with `PROSCA:`** are protocol messages (parsed as JSON, emitted as Tauri events)
- **Other stdout lines** are ignored (Julia noise)
- **Stderr** is logged at debug level

### Key protocol messages

**Agent -> GUI:** `agent_message`, `tool_call_request`, `tool_result`, `agent_done`, `error`, `ready`, `config`, `skills`, `mcp_servers`

**GUI -> Agent:** `user_message`, `tool_approval`, `command`, `reset`, `config_get`, `config_set`, `skills_list`, `mcp_list`

### State Management

React context + hooks (no Redux):
- `SidecarContext` — Tauri IPC bridge (`invoke`/`listen`), connection status
- `ChatContext` — messages array + `useReducer`, agent busy state
- `ConversationContext` — conversation list (in-memory, no persistence yet)
- `SettingsContext` — config sync with backend, theme (localStorage)

### Path Alias

`@/*` maps to `./src/*` (configured in both `tsconfig.json` and `vite.config.ts`).

## Conventions

- CSS uses design tokens via custom properties (see `tokens.css`). Light/dark themes via `[data-theme="dark"]`.
- No CSS modules or preprocessors — plain CSS with BEM-ish class names.
- Components use default exports. Contexts export both the Provider and a `useX()` hook.
- Tool call IDs are serialized as strings (Julia `UInt64` can exceed `Number.MAX_SAFE_INTEGER`).
- No streaming — `call_llm` is blocking. Messages arrive whole, with a working indicator while waiting.

## Known Limitations

- Conversations are in-memory only (no SQLite persistence yet — needs backend `conversations` table)
- Routines page is a placeholder (needs backend cron scheduler)
- No streaming responses
- `PROSCA_DIR` env var or exe-relative walk used to find the Prosca project root
