# NXP MBDT AI Support - Configuration and Troubleshooting

Supplementary detail for installing, verifying, updating, and troubleshooting the NXP MBDT AI Support. See the main [README.md](README.md) for the primary install walkthrough.

## Table of Contents

- [Verify Your Setup](#verify-your-setup)
- [Updating & Uninstalling](#updating--uninstalling)
- [`registerAgent` Reference](#registeragent-reference)
- [`registerSkills` Reference](#registerskills-reference)
- [Troubleshooting](#troubleshooting)

---
## Verify Your Setup

After completing Steps 1-4 of the README, confirm your agent can actually reach the MBDT MCP tools and skills:

- **MCP tools** - ask your agent to run `detect_matlab_toolboxes`. It should list your installed NXP MBDT toolboxes (e.g. "Model-Based Design Toolbox for S32K3 Series").
- **Skills** - check your agent's skill listing. The MBDT skills (`building-mbdt-model`, `configuring-mbdt-blocks`, etc.) should appear.
- **MATLAB path** - run `which nxp.setup.registerAgent` in MATLAB; it should resolve to a path under your MBDT AI Support clone/install.

If any check fails, see [Troubleshooting](#troubleshooting).

---
## Updating & Uninstalling

**Update:**
- NXP MBDT AI Support: pull the latest changes (or download the latest release), then re-run `mbdt_ai_support_path` and the registration commands (README Steps 3-4).
- MathWorks stack: re-run `setupAgenticToolkit("update")`.

**Uninstall:**
- NXP MBDT AI Support: run `mbdt_ai_support_path("remove")`, then remove the registered MCP entry and the skills copies from your agent's own config / skills folder - there is no automated uninstall helper for these yet.
- MathWorks stack: run `setupAgenticToolkit("uninstall")`.

---
## `registerAgent` Reference

```matlab
nxp.setup.registerAgent("agent","<agent>")
```

| `<agent>` value | Behavior |
| --------------- | -------- |
| `"goose"` (default) | Writes the MCP config automatically to Goose's `config.yaml`. |
| Any other value (e.g. `"claude"`, `"codex"`, `"copilot"`) | Prints a ready-to-paste MCP JSON snippet with the resolved executable and `--extension-file` arguments; add it to that agent's MCP config file yourself. This is a documented fallback, not an error, and works for any MCP-compatible agent. |

`agent` also accepts a list, e.g. `["goose","codex"]`, to register several hosts in one call.

Optional parameters:
- `mcp_arguments` - extra command-line arguments appended to `matlab-mcp-server.exe` (see README Step 3.1).

## `registerSkills` Reference

```matlab
nxp.setup.registerSkills("agent","<agent>")
```

| `<agent>` value | Skills install location |
| --------------- | ------------------------ |
| `"claude"`      | `~/.claude/skills`        |
| `"codex"`       | `~/.agents/skills`        |
| `"copilot"`     | `~/.agents/skills`        |
| `"goose"`       | `~/.agents/skills`        |

Unlike `registerAgent`, `registerSkills` strictly validates `agent` against this fixed list and throws an `unknownAgent` error for anything else (it does not fall back to a manual snippet). Use `"location","<path>"` instead of `"agent"` to install into any custom folder (README Step 4.2); `agent` and `location` are mutually exclusive.

Optional parameters:
- `links=true` - install as symlinks/junctions instead of copies, for live updates from the source `skills-catalog/` (README Step 4.1).

---
## Troubleshooting

| Symptom | Cause / Fix |
| ------- | ----------- |
| `setupAgenticToolkit` / `nxp.setup.*` functions unresolved right after installing or updating the add-on | Newly installed or updated add-on files can be staged under `...\MATLAB Add-Ons\setup_installer_staging@<version>\` and are not on the MATLAB path until MATLAB restarts. Restart MATLAB; if you cannot, `addpath` that staging folder manually as a workaround. |
| `registerAgent` errors with `missingSetup` | `setupAgenticToolkit` is not on the MATLAB path. Install the MathWorks Agentic Toolkit Setup add-on first (README Step 1). |
| `registerAgent` errors with `toolkitPathMissing` | The NXP MBDT AI Support is not on the MATLAB path. Run `mbdt_ai_support_path` first (README Step 2). |
| `registerAgent` only printed a JSON snippet instead of writing config | Expected for every agent except `"goose"` - see [`registerAgent` Reference](#registeragent-reference). Paste the snippet into that agent's MCP config file. |
| `registerSkills` throws `unknownAgent` | The value is not one of `claude` / `codex` / `copilot` / `goose` - see [`registerSkills` Reference](#registerskills-reference), or use `"location"` with an explicit folder. |
| `links=true` fails on Windows | A directory symlink needs Developer Mode or MATLAB run as Administrator; the junction fallback needs the source and destination on the same drive. Use the default copy mode or a `location` on the same drive. |
| Running on a MATLAB release newer than the toolbox's declared metadata range | Usually fine - the MCP Tools and Skills resolve the installed toolbox at runtime rather than hard-coding a release - but it is not formally validated. Check the declared range with `detect_matlab_toolboxes` or `ver` in MATLAB. |
