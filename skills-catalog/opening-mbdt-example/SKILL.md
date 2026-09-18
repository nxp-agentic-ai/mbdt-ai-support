---
name: opening-mbdt-example
description: "Use when the user asks to open, load, copy, try, browse, or list NXP MBDT shipped examples for any supported platform (S32K3). Triggers on: 'open example', 'load example', 'show me an example', 'copy example to workspace', 'what examples are available', 'list MBDT examples', 'give me a starting example for S32K3', 'what demos ship with MBDT', 'browse MBDT demos'. Discovers valid example names at runtime via get_mbdt_toolbox(family, 'examples') and copies via open_mbdt_example; never fabricates example names. Out of scope: building/compiling (use building-mbdt-model), configuring blocks or model params (use setting-mbdt-model-params or configuring-mbdt-blocks), changing target MCU (use setting-mbdt-target-mcu), installing/updating MBDT (use installing-mbdt), code generation with slbuild or S32CT, PIL testing, FreeMASTER, EB tresos, or creating new blank models from scratch."
license: LA_OPT_Online Code Hosting NXP_Software_License
metadata:
  author: NXP
  version: "1.0.0"
  product: nxp-mbdt
  tags: '[mbdt, examples, open]'
---

# Opening an NXP MBDT Shipped Example

Use this skill to copy an NXP MBDT shipped example into a working folder and switch into it, exactly as the toolbox's `nxp.utils.openExample` would when invoked from the UI. The skill dispatches to two MCP tools and never inlines their behavior:

- **`get_mbdt_toolbox(family, 'examples')`** -- discovers the live catalog of valid example names for a family.
- **`open_mbdt_example`** -- performs the copy.

The list of valid example names is **always retrieved at runtime** by calling `get_mbdt_toolbox(family, 'examples')`, which reads the toolbox's own `help/examples.xml` manifest. It is never hard-coded in this skill, never copied from memory, and never fabricated by the agent. The action itself is performed by `open_mbdt_example` -- do not re-implement it inline, and do not call `nxp.utils.openExample` or `mbd_{family}.nxp.openexample` directly through `evaluate_matlab_code`.

## When to Use

- The user asks to open, load, try, or copy an example shipped with any NXP MBDT toolbox.
- The user asks to list the examples available for an MBDT family.

## When NOT to Use

- The user wants to open the external configuration tool for an existing model -> use `opening-mbdt-config-tool`.
- The user wants to change the configuration template of a model that is already open -> use `setting-mbdt-target-mcu`.
- The user wants to open a model that is *not* a shipped MBDT example (their own model, or a non-MBDT example) -> use `open_system` (or `evaluate_matlab_code`) directly; this skill is not needed.

## Workflow

1. **Identify the target family.** Determine which MBDT family the request applies to (`s32k3`). If the user did not name one and only one MBDT toolbox is installed, use that family. Otherwise, ask.

2. **Discover the live catalog.** Call `get_mbdt_toolbox(family, 'examples')`. Treat its output as the **single source of truth** for valid example names. The skill never carries a memorized list, and the agent never fabricates a name.

3. **Resolve the user's wording to a canonical example name returned by the discovery tool.** If the resolved name is not in the live list, present the available examples and ask the user to choose. Never coerce a near-miss.

4. **Decide whether to pass the optional arguments** -- see [Arguments](#arguments) below. The default is to pass **only** `example` and `family`.

5. **Apply the change** by calling the `open_mbdt_example` MCP tool with the resolved example name first, the **same `family`** that was used in step 2 for discovery second (never a different one, never a freshly-guessed one), and only the optional arguments the user explicitly justified. The MATLAB-side signature is `open_mbdt_example(example, family, WorkDir, Overwrite)` -- **all four arguments are positional**, in that exact order. `example` and `family` are required; `WorkDir` (default `"matlab"`) and `Overwrite` (default `false`) are optional. To pass `Overwrite` you must also pass `WorkDir` -- use the sentinel `"matlab"` to keep the default destination behavior.

6. **Report** briefly: the example name, the destination folder it landed in, and whether a fresh copy was made or an existing one was reused.

## Arguments

The `open_mbdt_example` tool takes exactly **two required** and **two optional** arguments. The rule for the optional ones is **simple and strict: omit optional arguments unless the user explicitly asked for the behavior they control.**

### `example` *(required)*

The canonical example name returned by `get_mbdt_toolbox(family, 'examples')`. Pass it through unchanged.

### `family` *(required)*

The MBDT toolbox family identifier (`s32k3`). Pass the **same value** that was used in step 2 for `get_mbdt_toolbox`. The agent must never call the discovery tool against one family and then `open_mbdt_example` against another -- the example name space is per-family, and the resolved family also selects which installed MBDT toolbox the example is copied from. Do not derive `family` from the example name string (e.g. parsing the `s32k3_` prefix); always reuse the family the user named (or that the agent resolved deterministically in step 1).

### `WorkDir` *(optional, positional -- default `"matlab"`; pass an explicit path ONLY when the user specifies a destination)*

A literal folder path under which a subfolder named after the example will be created (e.g. `WorkDir = "C:\work"` -> example lands at `C:\work\{example}\`), **or** the sentinel string `"matlab"` which selects MATLAB's per-release examples directory.

- **Omit this argument by default**, or -- equivalently -- pass the sentinel value `"matlab"`. When `WorkDir == "matlab"` the tool drops the example under `matlab.internal.examples.getExamplesDir() + "nxp{family}" + "{example}"` -- the same location the toolbox uses by default and the safest cross-session choice.
- **Pass an explicit folder path only when the user names a destination folder** -- e.g. *"open it in `C:\projects\demo`"*, *"open it here"* (use `pwd`), *"open it under my current folder"* (use `pwd`).
- The folder is created if it does not exist; paths longer than 128 characters trigger a non-blocking warning from the tool.

### `Overwrite` *(optional, positional -- default `false`; pass `true` ONLY when the user asks for a fresh / new / default example)*

A boolean. Default is `false` (the tool reuses any existing copy at `{WorkDir}/{example}`, preserving user edits).

- **Omit this argument by default** (or, equivalently, leave it at `false`). The tool will reuse the existing copy if one is present.
- **Pass `Overwrite = true` only when the user explicitly asks for** a *new*, *fresh*, *reset*, *clean*, or *default* copy of the example -- phrasings like *"give me a fresh copy"*, *"reset the example"*, *"start over"*, *"a new example"*, *"the default example"*, *"discard my changes and re-copy"*. The tool then removes the destination tree and re-copies from the toolbox source.
- Because `Overwrite` is positional and comes after `WorkDir`, you must also supply `WorkDir` to reach it -- use the sentinel `"matlab"` when you want the default destination together with `Overwrite = true`.
- Never pass `Overwrite = true` to "play it safe" or as a routine flag -- it discards any saved user edits in that folder.

## Errors raised by `open_mbdt_example`

The tool raises named MATLAB errors. If the call fails, recognize the identifier and respond accordingly -- do not retry blindly.

| Identifier | Meaning | Correct response |
|---|---|---|
| `open_mbdt_example:ToolboxNotOnPath` | The `Model-Based Design Toolbox for S32{family}...` product is not installed (or `mbd_find_{family}_root` is missing from the path). | Stop. Report the missing product to the user. Do not retry with a different family. |
| `open_mbdt_example:InvalidToolboxRoot` | `mbd_find_{family}_root` returned a path that does not exist on disk. | Stop. Report the broken toolbox install to the user. |
| `open_mbdt_example:ExamplesXmlNotFound` | The toolbox's `help/examples.xml` is missing under the resolved install root. | Stop. Report the broken toolbox install to the user. |
| `open_mbdt_example:UnknownExample` | The `example` name is not in the family's live catalog. | Re-run `get_mbdt_toolbox(family, 'examples')`, present the live list, and ask the user to choose. **Do not** silently coerce to a near-miss. |
| `open_mbdt_example:InvalidWorkDir` | `WorkDir` failed `matlab.internal.examples.validateWorkDir`. | Surface the wrapped message and ask the user for a different destination. Do not silently substitute `pwd` or another path. |
| `open_mbdt_example:WorkDirTooLong` | (Warning, not an error.) The resolved destination exceeds 128 characters. | Forward the warning to the user; the copy still proceeds. |
| `open_mbdt_example:OverwriteCleanFailed` | `Overwrite = true` was passed but the existing destination tree could not be removed (locked files, permissions, etc.). | Stop. Ask the user to close files at that location or pick a different `WorkDir`. Do not retry without `Overwrite`. |

## Examples

| User says | What the agent does |
|---|---|
| "List the MBDT examples for this family." | Calls `get_mbdt_toolbox(family, 'examples')` with the resolved `family`; reports the live catalog. |
| "Open a specific MBDT example." | Discovers the live catalog with `get_mbdt_toolbox(family, 'examples')`; resolves the user's wording to a canonical example name; calls `open_mbdt_example(example, family)` with the **same** `family` (no `WorkDir`, no `Overwrite`). |
| "Open the example here / under my current folder." | As above, but also passes `WorkDir = {pwd}` (positional, 3rd argument) so the example lands under the current MATLAB folder. |
| "Open the example in `C:\projects\demo`." | As above, but passes `WorkDir = "C:\projects\demo"` (positional, 3rd argument) so the example lands at `C:\projects\demo\{example}\`. |
| "Open the example again." (destination already populated, no other qualifier) | Calls `open_mbdt_example(example, family)` only; the tool detects the existing copy and reuses it as-is. |
| "Give me a fresh copy of the example." / "Reset the example." / "I want the default example." / "Start over with a new example." | Calls `open_mbdt_example(example, family, "matlab", true)` -- uses the sentinel `WorkDir = "matlab"` to keep the default destination together with `Overwrite = true`. If the user also specified a destination, substitute that path for `"matlab"`. The tool removes the existing copy and re-copies from the toolbox source. |

## Guardrails

- **Never fabricate values.** Do not invent, memorize, or guess example names or MBDT family identifiers. Always call `get_mbdt_toolbox(family, 'examples')` first and accept only entries it returns. If the discovery tool is unavailable, fall back to a generic tool (e.g. `evaluate_matlab_code` reading the family's `help/examples.xml` under the toolbox install root) or ask the user -- never fabricate a value from memory.
- **Never operate on a microcontroller without first verifying the MBDT family toolbox is installed.** Before copying or opening an example for a given family, call the MCP tool `detect_matlab_toolboxes` (or, as a MATLAB-side fallback, run `ver` with no arguments and inspect the `Name` field) and require an entry matching `Model-Based Design Toolbox for S32{family}...` (e.g. `Model-Based Design Toolbox for S32K3 Series`). A family identifier being acceptable to the discovery tool's enum is **not** proof of installation, and `get_mbdt_toolbox` returning data is **not** proof of installation either -- it is known to fall back silently to a different family's catalog when the requested family is missing. If the toolbox is not installed, stop, report the missing toolbox by its product name, and ask the user to install it or pick a family that is installed.
- **Never include implementation code in the workflow you describe.** This skill may name and reference *calls* to the `get_mbdt_toolbox` and `open_mbdt_example` MCP tools -- including the arguments described in prose -- but it must not contain the *implementation* of any functionality: no multi-statement scripts, no logic, no loops, no conditionals, no inline algorithms. If the workflow needs an action that does not map to an existing tool, stop and ask the user to create a new tool first; never inline the missing logic.
- **Always use `open_mbdt_example` to copy and open the example.** Do not call `nxp.utils.openExample` or `mbd_{family}.nxp.openexample` directly (e.g. via `evaluate_matlab_code`); bypassing the tool skips the example-name cross-check and the destination handling.
- **Omit `WorkDir` (or pass the sentinel `"matlab"`) unless the user explicitly specified a destination.** Do not invent a path, do not silently default to `pwd`, do not echo back a previously-used path. When the user did not name a destination, the sentinel `"matlab"` selects the tool's built-in default (MATLAB's per-release examples directory), which is the correct choice.
- **Omit `Overwrite` unless the user explicitly asked for a fresh / new / reset / default copy.** `Overwrite = true` deletes the existing destination tree and discards user edits -- never set it as a routine "safety" flag. Since `Overwrite` is positional and follows `WorkDir`, supplying it requires also supplying `WorkDir` -- use the sentinel `"matlab"` to keep the default destination.
- **Stop and ask the user** if more than one MBDT toolbox is installed and the user did not name a family. Do not pick one silently.

## Validation loop

1. After `open_mbdt_example` returns, confirm the destination folder exists on disk and contains the expected model file.
2. If `open_mbdt_example:UnknownExample` is raised, re-run `get_mbdt_toolbox(family, 'examples')` to get the current live catalog and present it to the user -- do not retry with a guessed name.
3. If `open_mbdt_example:OverwriteCleanFailed` is raised, stop and ask the user to close any files open at that location before retrying.
4. Report the example name, the destination folder it landed in, and whether a fresh copy was made or an existing one was reused.

## References

- **`open_mbdt_example` MCP tool** -- registered in `tools.json` and `registry.json` at the repository root, backed by `tools/open_mbdt_example/open_mbdt_example.m`. Single supported entry point for this skill. Signature: `open_mbdt_example(example, family, WorkDir, Overwrite)` -- **all four arguments are positional**, in that exact order. `example` and `family` are required; `WorkDir` (default `"matlab"`, the sentinel that selects MATLAB's per-release examples directory) and `Overwrite` (default `false`) are optional. `tools.json` `signatures.open_mbdt_example` declares `input.order = ["example", "family", "WorkDir", "Overwrite"]` (no `nameValue` block -- all arguments are positional).
- **`get_mbdt_toolbox(family, 'examples')` MCP tool** -- the discovery counterpart. Lists the live example catalog for a family by parsing the toolbox's `help/examples.xml`. Always call this first; never carry a memorized list.
