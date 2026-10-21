# Neovim workstation

The editor package is the active NvChad-based setup, not a screenshot of plugin names.

## Included behavior

- NvChad `v2.5` with the `penumbra_dark` skin.
- Lazy.nvim lockfile for reproducible plugin revisions.
- LSP/Mason for Lua, TypeScript, HTML, CSS and Python.
- Treesitter, nvim-cmp, LuaSnip, Spectre, Conform, hover and Pantran.
- Native Wayland clipboard through `wl-copy` and `wl-paste`.
- Avante as the single AI interface: provider/model switching, per-tab agents, file/buffer/quickfix context and drag-and-drop handling.
- Defensive compatibility guards for current Neovim/Avante window lifecycle behavior.

## AI providers without committed secrets

The live workflow reaches locally authenticated CLI proxies through loopback endpoints. Public defaults use `localhost`; every endpoint and model can be overridden:

```bash
export AVANTE_PROVIDER=codexcli
export AVANTE_CODEX_ENDPOINT=http://localhost:41337/v1
export AVANTE_CLAUDE_ENDPOINT=http://localhost:41338/v1
export AVANTE_GEMINI_ENDPOINT=http://localhost:41339/v1
export AVANTE_OLLAMA_ENDPOINT=http://localhost:11434
```

No API token is embedded. Direct cloud providers read their normal environment variables at runtime. Keep those values in a password manager or private environment loader.

## Clean installation smoke test

```bash
./scripts/test-neovim.sh
```

The script copies the editor into a disposable XDG/HOME sandbox so Lazy cannot modify the Stow-linked source lockfile. It waits for `Lazy! sync`, rejects error markers in both sync and startup logs, asserts NvChad, Treesitter, Avante and cmp loading, verifies the async-path Git origin, and confirms the source lockfile hash is unchanged. It does not call any external AI provider.

The publication gate also compiles every Lua file without executing provider calls.
