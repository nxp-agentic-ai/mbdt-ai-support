---
name: editing-mbdt-board-init
description: "Use when the user asks to view, list, dump, show, inspect, add, remove, enable, disable, reorder, reprioritize, comment, annotate, or edit any board-init component entry (`Mcu_Init`, `Port_Init`, `Adc_Init`, `Gpt_Init`, etc.) in the MBDT Board Initialization sequence of a Simulink model targeting any NXP MBDT platform (S32K3), including editing a component's Code block, Headers, Priority, or Enabled flag, or inserting/modifying lines inside `if`, `while`, or `#if` bodies in `mbdt_board_init.c` -- driven exclusively via `get_mbdt_board_init` / `set_mbdt_board_init` MCP tools. Do not activate for general Simulink block editing, slbuild, S32DS project setup, S32CT or EB tresos AUTOSAR configuration, PIL COM port setup, FreeMASTER integration, or Hardware Implementation pane parameters; activate only when the explicit subject is the `mbdt_board_init.c` initialization sequence or its component entries."
license: LA_OPT_Online Code Hosting NXP_Software_License
metadata:
  author: NXP
  version: "1.0.0"
  product: nxp-mbdt
  tags: '[mbdt, board-init, configuration]'
---

# Editing the NXP MBDT Board Initialization Sequence

Use this skill to **read or modify the Board Initialization sequence** of a Simulink model targeting any NXP MBDT platform. The sequence is the ordered list of component init calls (`Mcu_Init`, `Port_Init`, `Adc_Init`, ...) that MBDT emits into `mbdt_board_init.c` during code generation.

This skill is **deliberately thin**: it points the agent at the two MCP tools that encapsulate the whole read/write protocol -- platform detection, namespace resolution, two-layer persistence, on-disk verification, atomic rollback, and stale-GUI detection. **Do not** drive any of that machinery yourself via `evaluate_matlab_code`; the tools exist precisely so callers don't have to.

## Contract: Round-Trip Whole-Sequence

The tools form a single round-trip API:

1. **Read** with `get_mbdt_board_init(modelName, 'detail', {mode})`. Returns a struct with `components` -- a struct array, one entry per init component (`Mcu`, `Port`, `Adc`, ...) -- and additionally **prints a human-readable view of the sequence to stdout** as a side-effect. The print is controlled by the `detail` parameter (`summary` / `full` / `component` / `none`) and exists precisely so the agent can see component Names, Priorities, Headers, and Code lines **in one call**, without a follow-up `evaluate_matlab_code` to unfold the struct. See [Choosing a Detail Mode](#choosing-a-detail-mode) below.
2. **Mutate** `info.components` in any way the user asks: insert / replace / delete lines anywhere in a `Code` cellstr, change a `Priority`, toggle `Enabled`, append to `Header`, drop or reorder components.
3. **Write** with `set_mbdt_board_init(modelName, jsonencode(info.components))`. The tool validates, normalizes, persists both layers (in-memory `nxp.settings` + on-disk JSON in `CoderTargetData.Initialization.Sequence`), and independently re-reads the on-disk JSON to verify the change landed.

There is **no per-operation grammar** -- the contract is the whole sequence, every time. This is the only contract that can express edits which need to land in the *middle* of a Code block (e.g. inserting a heartbeat statement inside the PLL-lock `while` body of `Mcu`). A per-op grammar cannot represent "edit line 6"; the round-trip can.

The returned struct is **byte-identical regardless of `detail`** -- the parameter only changes what gets printed. Round-trip code that takes `info.components` and feeds it back to `set_mbdt_board_init` works unchanged with any `detail` mode.

## When to Use

- View / list / dump / show / inspect the board init sequence, any entry's Code, Headers, Priority, or Enabled flag.
- Add / remove / enable / disable / reorder / reprioritize / comment / annotate / edit an entry.
- Insert lines anywhere in a Code block, including the middle of `if`/`while`/`#if` bodies.
- Reset a single entry to its default -- read defaults via the tool, splice into the submitted sequence.
- Produce the fully resolved init code for the current sequence -- call `get_mbdt_board_init` and present the `Code` cellstr of each entry.

## When NOT to Use

- The user wants to **change the target MCU / hardware part / configuration template** -> use `setting-mbdt-target-mcu`. That regenerates the sequence; pre-editing entries about to be replaced is wasted work.
- The user wants to **open the external configuration tool (S32CT / EB tresos)** -> use `opening-mbdt-config-tool`. The board init sequence calls components' `_Init` functions; it does not configure their parameters.
- The user wants to set any other **Hardware Implementation field** (PIL, Clocking, Build, peripheral options, ...) -> use `setting-mbdt-model-params`.
- The user wants to **trigger code generation** and inspect `mbdt_board_init.c` on disk -> that is a build action. This skill operates on the template the build uses, not on the build output.
- The user wants to **add an entirely new component** that is not in the platform's `BoardInitData` catalog -> the codegen step has no template/headers/tokens for it. Custom user code belongs in a user-init hook, not in the sequence.

## Workflow

1. **Identify the model.** If unspecified, use the currently focused MBDT-targeted Simulink model; if multiple are open, ask which one.

2. **Always read first, with the right `detail` mode.** Call `get_mbdt_board_init(modelName, 'detail', {mode})` to obtain the live sequence. Pick `{mode}` per [Choosing a Detail Mode](#choosing-a-detail-mode):
   - `'summary'` (default) for structural edits (toggle `Enabled`, change `Priority`, append to `Header`) -- the printed table carries everything you need.
   - `'component'` + `'componentName', '{Name}'` when the user already named the component to edit (e.g. *"add a comment to the Mcu init"*) -- prints just that one component's `Header` and full `Code` cellstr line-by-line.
   - `'full'` when the user has not yet named the component and the edit will touch `Code` contents (e.g. *"find which component initializes the watchdog"*).
   - `'none'` when the sequence has already been printed earlier in the same turn and you only need the return struct.

   The return struct carries:
   - `platform` -- the MBDT family the tool auto-detected.
   - `source` -- `'customized'` (read from `nxp.settings`) or `'default'` (materialized via `gen_default_sequence`).
   - `components` -- struct array with `Name`, `Priority`, `Enabled`, `Header`, `Code`, `Tokens`. The first entry is the `Skipped` sentinel (`Priority=-Inf`, `Enabled=false`) and is excluded from `mbdt_board_init.c` emission; live entries are indices >= 2.
   - `gui_open` -- whether a Board Initialization AppDesigner dialog is currently open against this model.

   The returned struct is **byte-identical across all `detail` modes**; only what is printed to stdout changes.

3. **Resolve the user's intent against the live sequence.** Match the user's wording to a single component `Name` exactly. If ambiguous (e.g. "the CAN init" with both `Can_43_FLEXCAN` and `CanTrcv_43_AE` present), list candidates and ask -- never silently pick.

4. **Mutate the in-memory components array.** Standard MATLAB struct-array manipulation -- index by Name, edit `Code`/`Header`/`Priority`/`Enabled`/etc. in place. See "Recipes" below for the common shapes.

5. **Encode + write.**

   ```matlab
   set_mbdt_board_init(modelName, jsonencode(info.components));
   ```

   The tool will:
   - Validate every entry's shape (required fields present, Name in the platform's defaults, Priorities unique).
   - Re-inject the `Skipped` sentinel if it was dropped (and report `injected_sentinel=true`).
   - Restore each component's `Tokens` from defaults if it was dropped or arrived empty (and list affected names in `restored_tokens`).
   - Union in any default fields that aren't on the submitted entry (forward-compat with future MBDT releases; reported in `unioned_fields`).
   - Re-sort by `Priority` ascending.
   - Persist both layers in the documented order.
   - Independently re-read the on-disk JSON and deep-compare against the staged sequence (Name / Priority / Enabled / Header / Code).

6. **Decide whether to save.** Pass `'Save', true` only when the user explicitly asks for the change to survive a MATLAB restart. The default (`Save=false`) is enough for the change to be visible the next time the user opens the Board Initialization dialog from scratch in the same MATLAB session -- which is the most common request.

7. **Report.** Surface `applied`, `verified`, and the normalization flags. If `gui_stale` is true, warn the user that the open Board Initialization dialog now shows out-of-date information and that closing + reopening it will show the new state. If `saved` is false (default), explicitly tell the user the change is in memory only.

## Atomicity Contract

`set_mbdt_board_init` is **all-or-nothing**:

- The submitted sequence is fully validated and staged in a local copy before anything is written.
- If validation fails (malformed JSON, missing required field, unknown Name, duplicate Priority), an error is raised, **nothing is written to `nxp.settings`**, **nothing is written to the on-disk JSON**, and the model is left in its previous state.
- After both persistence layers are written, the on-disk JSON is re-read independently and deep-compared against the staged sequence. A mismatch raises `set_mbdt_board_init:VerifyFailed`.

There is no partial commit. When the user wants to stage many independent changes and is willing to accept partial success, the calling agent should split them into multiple separate read-mutate-write cycles.

## Normalization Applied at Write Time

Every successful `set_mbdt_board_init` call may report any of:

- **`injected_sentinel`** (logical) -- the submitted sequence was missing the `Skipped` entry and the tool re-inserted it at the front. Forgiving the agent for dropping it during slicing is the most common case.
- **`restored_tokens`** (cellstr) -- the named components had their `Tokens` field absent or empty and the tool restored them from `gen_default_sequence(hCS)`. Tokens are a `containers.Map(token_name -> resolver_callable)` at the MBDT layer; the callables don't survive a JSON round-trip. The tool restores them by Name; **agents are not required to reconstruct Tokens**.
- **`unioned_fields`** (cellstr of `'{Name}.{Field}'`) -- a field present on the per-component default but absent on the submitted entry was added in from the default. Forward-compat against MBDT releases that add new fields; lets agents send only what they want to change.

These are reported, not warned -- they are routine outcomes of the round-trip API. The skill exists so the agent can report them clearly to the user.

## Recipes

The five operations the previous op-based grammar exposed are all expressible as direct struct-array mutations:

### Add a comment to a Code cellstr (anywhere)

```matlab
% Cheapest read for a known-target Code edit: 'component' mode prints
% Mcu's Code line-by-line with cell indices, so the agent knows exactly
% which slice to use for the splice without a follow-up unfold call.
info = get_mbdt_board_init(modelName, 'detail','component', 'componentName','Mcu');
idx  = find(strcmp({info.components.Name}, 'Mcu'), 1);

% Top:
info.components(idx).Code = [{'/* reviewed */'}; info.components(idx).Code(:)];

% Bottom:
info.components(idx).Code = [info.components(idx).Code(:); {'/* reviewed */'}];

% Middle (e.g. after line 5):
c = info.components(idx).Code(:);
info.components(idx).Code = [c(1:5); {'/* checkpoint */'}; c(6:end)];

set_mbdt_board_init(modelName, jsonencode(info.components));
```

### Toggle Enabled

```matlab
% Structural edit -- the default 'summary' print is enough; no need to see Code.
info = get_mbdt_board_init(modelName);   % detail='summary' by default
idx  = find(strcmp({info.components.Name}, 'Spi'), 1);
info.components(idx).Enabled = false;
set_mbdt_board_init(modelName, jsonencode(info.components));
```

### Change Priority (move X before Y)

```matlab
% Structural edit -- the summary table shows every component's Priority.
info = get_mbdt_board_init(modelName);   % detail='summary' by default
iY = find(strcmp({info.components.Name}, 'Adc'), 1);
iX = find(strcmp({info.components.Name}, 'Pwm'), 1);
% Place X just before Y by giving it a priority halfway between Y and Y's
% predecessor. Inspect the existing priorities and pick a unique value.
info.components(iX).Priority = info.components(iY).Priority - 1;
set_mbdt_board_init(modelName, jsonencode(info.components));
```

### Add a header

```matlab
idx = find(strcmp({info.components.Name}, 'Mcu'), 1);
hdr = info.components(idx).Header;
if ~any(strcmp(hdr, 'MyDriver.h'))
    info.components(idx).Header = [hdr(:); {'MyDriver.h'}];
end
set_mbdt_board_init(modelName, jsonencode(info.components));
```

### Reset a single entry to default

There is no dedicated reset op; the agent reads the default and substitutes the entry:

```matlab
info     = get_mbdt_board_init(modelName);
defaults = i_eval('mbd_{family}.common.nxp.init.gen_default_sequence(getActiveConfigSet(''{model}''))');
% (Use evaluate_matlab_code with the platform-specific namespace.)
% Find the target in both arrays and overwrite the live entry.
idxLive = find(strcmp({info.components.Name}, 'Fee'), 1);
idxDef  = find(strcmp({defaults.Name},        'Fee'), 1);
info.components(idxLive) = defaults(idxDef);   % Tokens get restored anyway
set_mbdt_board_init(modelName, jsonencode(info.components));
```

For most users this is overkill -- offering "I'll regenerate the Fee defaults for you, then send the sequence" is enough explanation.

## Choosing a Detail Mode

The `detail` parameter on `get_mbdt_board_init` controls **what gets printed to stdout** so the agent can see the sequence in one call instead of issuing a follow-up `evaluate_matlab_code` to unfold the returned struct. The returned struct is byte-identical regardless of `detail`; only the printed view changes. Pick the cheapest mode that exposes what the next step needs:

| `detail` | What gets printed | When to use |
|---|---|---|
| `'summary'` *(default)* | One-row-per-component table: `#`, `Priority`, `Enabled`, `Name`, `#Code` (line count), `#Header` (include count). The `Skipped` sentinel at index 1 is included so the agent's indexing matches what `set_mbdt_board_init` validates against. | Structural / metadata edits where Code line content is not needed: toggle `Enabled`, change `Priority`, reorder, append to `Header`. Also the right pick for "show me the board init sequence" or "which components are enabled?" Cheapest option. |
| `'component'` | The summary header plus **one** named component's `Header` list and full `Code` cellstr line-by-line (one `printf` per line, with the cell index). Requires a paired `componentName` argument. Raises `get_mbdt_board_init:UnknownComponentName` if the name does not match a live entry. | Mid-Code edits where the target component is already known: *"add a comment to the Mcu init"*, *"insert a `goose was here` inside the PLL-lock `while` body"*, *"swap line 5 of Adc's Code"*. Second-cheapest option; preferred over `'full'` whenever the target is known. |
| `'full'` | The summary table plus **every** component's `Header` list and `Code` cellstr (Skipped sentinel skipped). | The user has not yet named the component but the next edit will touch Code contents -- e.g. *"find the component that calls `Mcu_DistributePllClock`"*, *"which init uses the LIN headers?"* Most expensive on context; only use when discovery genuinely requires it. |
| `'none'` | Nothing. | The sequence was already printed earlier in the same turn (e.g. the agent re-reads after a write to confirm and the user has already seen the table). Avoids printing the same payload twice. |

**Default to `'summary'`.** Step up to `'component'` only when about to mutate one named component's `Code`; step up to `'full'` only when discovery genuinely requires seeing every component's contents. Stepping down to `'none'` is appropriate only when something *else* in the same turn has already printed the same data.

## Defaults and Disambiguation

- If the user names a component ambiguously, list candidates (matched by `Name`) and ask. Don't silently pick.
- For *enable / on / true / yes / 1 / check* normalize to `Enabled = true`; for *disable / off / false / no / 0 / uncheck* normalize to `Enabled = false`.
- For "move X before Y": read the sequence, find Y's priority and the priority of the entry immediately before Y, set X's priority to a unique value strictly between those two.
- For "add a comment" without a position hint, prepend (top of Code cellstr). For "annotate" / "mark" / "tag" likewise.
- For "insert inside the while": find the line containing the matching `{` and the line containing the matching `}`, splice into the slice between them. Show the agent's plan back to the user before writing, especially if the surrounding code is non-trivial.

## Examples

| User says | What the agent does |
|---|---|
| "Show me the board init sequence for `{model}`." | Calls `get_mbdt_board_init(modelName)` (default `detail='summary'`). The tool prints the per-component table directly; the agent relays it. Notes whether `source` is `'customized'` or `'default'`. |
| "Show me the Mcu init code." | Calls `get_mbdt_board_init(modelName, 'detail','component', 'componentName','Mcu')`. The tool prints just that component's `Header` and `Code` cellstr line-by-line. |
| "Dump the full board init." | Calls `get_mbdt_board_init(modelName, 'detail','full')`. The tool prints the summary table plus every component's Header + Code. Use sparingly -- expensive on context. |
| "Add a comment `/* reviewed */` to the Mcu init." | Calls `get_mbdt_board_init(modelName, 'detail','component', 'componentName','Mcu')`, prepends to `info.components(idx).Code`, calls `set_mbdt_board_init`. Reports `applied=true`. |
| "Disable the Spi entry." | Calls `get_mbdt_board_init(modelName)` (default summary -- structural edit, Code contents not needed), sets `info.components(idx).Enabled = false`, writes. |
| "Move Pwm before Adc." | Calls `get_mbdt_board_init(modelName)` (default summary -- the printed table shows every Priority), computes a unique priority between Adc and its predecessor, sets it on Pwm, writes. |
| "Reset the Fee entry to its default." | Calls `get_mbdt_board_init(modelName)` (default summary), fetches defaults via the platform namespace, substitutes the entry, writes. |
| "Insert a comment inside the PLL-lock while in Mcu." | Calls `get_mbdt_board_init(modelName, 'detail','component', 'componentName','Mcu')` -- the printed Code listing shows the cell-index line numbers needed to locate the `{` and `}` of the `while` body. Splices the comment between them and writes. |
| "Save the board init so it survives a restart." | Re-call `set_mbdt_board_init` with `'Save', true`. |
| "Open the Board Initialization dialog." | Out of scope -- use `setting-mbdt-model-params` on `(Hardware, Initialization_Configure)`. |
| "Add a brand-new `MyDriver_Init();` call to the sequence." | Tell the user this skill cannot add entries that are not in the platform's `BoardInitData` catalog. Suggest a user-init hook or extending the toolbox. |

## Ordering Invariants

`gen_board_init_c` (the MBDT renderer that emits `mbdt_board_init.c`) walks `ModelComponents` in **storage order** and never re-sorts. The MCP guarantees that after **every** successful `set_mbdt_board_init` write the stored array is canonical, regardless of which field was edited:

1. The `Skipped` sentinel is at index 1 (`Priority = -Inf`).
2. Remaining components are sorted by `Priority` ascending.
3. Ties on `Priority` are broken alphabetically by `Name`, so multiple `Custom_*` blocks all at `Priority = Inf` have a deterministic emit order across MATLAB versions.
4. Empty / `NaN` `Priority` values are promoted to `Inf` before sorting (matching the rescue `gen_default_sequence` performs on the default path).

This canonicalization runs even on non-`Priority` edits, so any prior drift left in the store by the GUI's `AddImageClicked` / `reorderComponent`, by an external `.mat` template, or by a manual `evaluate_matlab_code` is **repaired by the next MCP write**. If you observe a scrambled `mbdt_board_init.c` after a non-MCP touch, an idempotent `Code` re-write of any component is enough to restore canonical order; an explicit `Priority` edit is not required.

To **change** the emit order, edit the `Priority` field directly:

```
set_mbdt_board_init(modelName, 'Adc', 'Priority', '5')        % JSON number
set_mbdt_board_init(modelName, 'Custom_diag', 'Priority', 'Inf')  % string Inf
```

`Priority` accepts a JSON number (e.g. `'5'`, `'-3.5'`) or the string `'Inf'` (case-insensitive, with or without quotes). `'-Inf'` is reserved for the `Skipped` sentinel and is rejected for any other component; `NaN`, non-real, and non-scalar values are also rejected. Unlike the prior "pick a value strictly between two neighbors" recipe (which assumed strict uniqueness), the tie-break on `Name` means two entries can safely share the same `Priority` -- they will land in alphabetical order.

## Guardrails

- **Never fabricate runtime values.** Component names, priorities, header includes, init-function names, token maps, C code bodies, and file paths are never invented by the author or the agent. Every such value comes from a runtime discovery call (`get_mbdt_board_init` for the live sequence, `evaluate_matlab_code` against the `mbd_{family}.common.nxp.*` package). If discovery is unavailable, stop and ask the user. Any component name or code shown in this skill's examples is an illustrative placeholder, never an asserted catalog fact.

- **Never bypass the tools.** Do not call `nxp.settings.*`, `nxp.init.*`, `codertarget.data.setParameterValue('Initialization.Sequence', ...)`, or any other MBDT internal from `evaluate_matlab_code` for the *write* side. The tool handles platform detection, namespace resolution under `mbd_{family}.common.nxp.*`, two-layer write ordering, and on-disk verification. The tool's `set_mbdt_board_init:VerifyFailed` error exists to catch half-finished writes; bypassing the tool defeats that.

- **Never write the on-disk JSON directly.** `codertarget.data.setParameterValue(hCS, 'Initialization.Sequence', ...)` without first updating `nxp.settings` will be silently overwritten on the next GUI open. The tool always writes both layers in the right order; agents must let it.

- **Never assume `Save=true`.** The user gets visibility into edits via the next "open Board Initialization dialog" -- that is what the in-memory write delivers and that is what most users want. Persisting to disk via `save_system` is a separate user choice. Default `Save=false`; ask if unclear.

- **Never strip the `Skipped` sentinel deliberately.** It will be re-injected, but the agent's mental model of the sequence should always include it. Slicing `info.components(2:end)` and feeding that back will work (the tool reinjects), but it muddies the diff for the user.

- **Never reuse priorities.** `set_mbdt_board_init:DuplicatePriority` rejects the whole write when two entries share a finite `Priority`. When reordering, pick a unique value (e.g. halfway between two neighbours).

- **Never silently accept ambiguous component names.** If the user says "the CAN entry" and the sequence has multiple matches, list candidates and ask. `set_mbdt_board_init:UnknownComponent` will reject any Name not in the platform's defaults, but it cannot disambiguate between two equally valid ones.

- **Always surface `gui_stale`.** When the tool reports an open Board Initialization GUI is now stale, tell the user explicitly. The AppDesigner app caches `ModelComponents` at construction time and does not auto-refresh.

- **Always surface `injected_sentinel`, `restored_tokens`, `unioned_fields`** when non-empty. These are not errors, but the user deserves to know what the tool normalized -- especially the Tokens restoration, which is invisible from a `jsonencode` diff but matters at codegen time.

- **Never operate without verifying the target MBDT toolbox is installed.** `get_mbdt_board_init:NamespaceMissing` is raised when `mbd_{family}.common.nxp.*` is not on the path. Report verbatim -- never substitute a different family's tools.

- **Never unfold the returned struct with `evaluate_matlab_code` just to see what is in it.** The `detail` parameter on `get_mbdt_board_init` exists precisely so the agent does not need a follow-up call to print `info.components(idx).Code{:}` or `{info.components.Name}`. Pick the right `detail` mode at read time (see [Choosing a Detail Mode](#choosing-a-detail-mode)) -- `'summary'` for structural edits, `'component'` for known-target Code edits, `'full'` only when discovery genuinely requires it, `'none'` to suppress reprints. Calling `get_mbdt_board_init` and then `evaluate_matlab_code` to dump the same data wastes a tool call and doubles the context cost; this is the single most common avoidable inefficiency in the board-init workflow.

- **Never invent a `componentName` for `detail='component'`.** It must match a `Name` returned by an earlier read (the `'summary'` table is the cheapest source). The tool raises `get_mbdt_board_init:UnknownComponentName` with the live name list; surface that list to the user rather than retrying with a guess.

## Validation loop

1. After `set_mbdt_board_init` returns, check `applied=true` and `verified=true` in the returned struct.
2. If `gui_stale` is true, warn the user that the open Board Initialization dialog is out of date.
3. Surface `injected_sentinel`, `restored_tokens`, and `unioned_fields` when non-empty -- they are routine but the user should know.
4. If `set_mbdt_board_init:VerifyFailed` is raised, do not retry; surface the error and ask the user to inspect the on-disk JSON.

## References

- `get_mbdt_board_init` -- MCP tool that returns the live sequence (auto-detects platform, falls back to `gen_default_sequence` when uncustomized, normalizes Tokens to cellstr for transport). Accepts a `detail` Name-Value (`'summary'` / `'full'` / `'component'` / `'none'`) and a paired `componentName` to print a human-readable view of the sequence to stdout as a side-effect; the returned struct is byte-identical regardless of mode.
- `set_mbdt_board_init` -- MCP tool that validates, normalizes, persists, and verifies a whole sequence in one call. Round-trip contract: take what `get_mbdt_board_init` returned, mutate, `jsonencode`, hand back.
- `setting-mbdt-model-params` -- the skill for opening the Board Initialization GUI (via the `Initialization_Configure` pushbutton in the Hardware group).
- `setting-mbdt-target-mcu` -- the skill for changing the target MCU; that operation regenerates the sequence and supersedes any pre-existing customization.
