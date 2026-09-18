---
name: setting-mbdt-model-params
description: "Use when the user asks to set, change, update, enable, disable, configure, fire, or pick any Configuration Parameters -> Hardware Implementation -> Target hardware resources field on an NXP MBDT Simulink model (S32K3) via set_mbdt_model_param, including PIL baudrate or update button, Clocking source or frequency, Build options, External mode, FreeMASTER settings, or the Board Initialization configure pushbutton (Initialization_Configure). For serial COM port dropdowns (PIL COM port, External Mode COM port, FreeMASTER serial port) use refreshing-mbdt-com-ports instead; for changing the target MCU or hardware template use setting-mbdt-target-mcu."
license: LA_OPT_Online Code Hosting NXP_Software_License
metadata:
  author: NXP
  version: "1.0.0"
  product: nxp-mbdt
  tags: '[mbdt, parameters, configuration]'
---

# Setting NXP MBDT Model Parameters

Use this skill to change a Configuration Parameters value on a Simulink model that targets any NXP MBDT platform, exactly as if the user had opened the **Configuration Parameters -> Hardware Implementation -> Target hardware resources** pane and modified the field there. The skill dispatches to the single MATLAB tool `set_mbdt_model_param`, which fires the parameter's MBDT callback the same way the live dialog does (so dependent / derived fields stay coherent).

Valid parameters the agent may set -- groups, tags, tooltips, widget types, dropdown entries, and current values -- are **always retrieved at runtime** from the `detect_mbdt_params` MCP tool. No parameter name, group name, or accepted value may be carried in from training data.

## When to Use

- The user asks to **set / change / edit / configure / update / modify / enable / disable / check / uncheck / pick** a value for a Configuration Parameters field on an MBDT-targeted model.
- The user names a parameter by tag (e.g. `PIL_COMPort`, `CPU_Clock_in_MHz`), by group + name (e.g. "the COM port in PIL"), by tooltip-style description (e.g. "the parameter that selects the PIL serial port"), or by visible label.
- The user changed the target MCU (often via `setting-mbdt-target-mcu`) and now wants to tune a downstream parameter that has been regenerated on the model.
- The user asks to fire a pushbutton parameter (e.g. an `update_*` action) on the pane.

## When NOT to Use

- The user asks to **change the target MCU / processor / hardware part / custom board / configuration template** -> use `setting-mbdt-target-mcu`. That action drives a different dropdown and a different reconciliation flow.
- The user asks to **open the external configuration tool (S32CT / EB tresos)** -> use `opening-mbdt-config-tool`.
- The user asks to **read** a parameter without changing it -> call `detect_mbdt_params` (and, if needed, `get_param` / `codertarget.data.getParameterValue` via `evaluate_matlab_code`) and report. Do not invoke this skill.
- The user asks to set a parameter that is not on the **Hardware Implementation -> Target hardware resources** pane (e.g. a Solver, Diagnostics, or Code Generation field) -> use plain `set_param` via `evaluate_matlab_code`; those have no MBDT callback to drive.

## Workflow

1. **Identify the model and active configuration.** If the user did not name a model, use the currently focused MBDT-targeted Simulink model; if multiple are open, ask which one. The model must be loaded so its active `Simulink.ConfigSet` is reachable via `getActiveConfigSet`.

2. **Detect the MBDT platform** for the model (one of the supported family keys accepted by `get_mbdt_toolbox`) and verify the matching MBDT toolbox is installed via `detect_matlab_toolboxes`. If the toolbox is missing, stop, name the product (e.g. *Model-Based Design Toolbox for S32K3 Series*), and ask the user -- never substitute a different family's parameter catalog.

3. **Discover the live parameter catalog** for that platform by calling `detect_mbdt_params` with the detected family. Its output is a struct of groups -> parameter leaves, where each leaf carries `Tag`, `Name`, `ToolTip`, `Type`, `Entries`, `EntriesType`, `Storage`, and `Callback`. This output is the **single source of truth** for what may be set on this model.

4. **Resolve the user's wording to a canonical (group, tag) pair.** Search the discovered catalog against the user's phrasing using, in priority order: (a) exact match on the leaf `Tag`, (b) exact match on a group name + leaf `Tag`, (c) substring match on the leaf `Name` (visible label), (d) substring match on the leaf `ToolTip` (which describes what the parameter does). If two or more leaves match equally well, list the candidates (group, tag, ToolTip) and ask the user to pick. If nothing matches, list the available groups and ask -- never coerce a near-miss, never invent a tag.

5. **Confirm the parameter is settable in this skill's scope.** Check the leaf's `Type` against the supported widget types of `set_mbdt_model_param`: `pushbutton`, `combobox` / `dropdown` / `popup`, and `checkbox`. If the resolved leaf is of any other widget type (free text, numeric edit, ...), stop and tell the user this skill only drives those three widget kinds -- suggest plain `set_param` via `evaluate_matlab_code` for text/numeric fields.

6. **Resolve the user's intended value** against the leaf:
   - For **dropdown** parameters: map the user's wording to one of the entries the catalog reports (or, for `EntriesType: callback`, to one of the entries the live callback returns). Accept either a 0-based index or the entry label. Refuse near-misses.
   - For **checkbox** parameters: map the user's wording to a boolean -- `on`/`off`, `true`/`false`, `enable`/`disable`, `check`/`uncheck`, `yes`/`no`, `1`/`0` are all acceptable.
   - For **pushbutton** parameters: no value is needed; the action is to fire the callback once.
   See [Defaults and Disambiguation](#defaults-and-disambiguation) for the canonical aliases.

7. **Apply the change** by calling `set_mbdt_model_param` (see [Applying the Change](#applying-the-change)). This is the single supported entry point; it builds the same `utils.HdlgWrapper` the live dialog would, pushes the chosen value into the live widget, and fires the parameter's `Callback` so any dependent fields update atomically.

8. **Report** briefly: model name, resolved (group, tag) pair, the leaf's `ToolTip` (so the user sees what was actually changed), the previous and new values, and any derived field the callback updated.

## Defaults and Disambiguation

- If the user names a parameter ambiguously (e.g. "the COM port"), search `Tag`, then `Name`, then `ToolTip` in that priority order; if more than one leaf still matches, **stop and ask**. Do not silently pick.
- *enable* / *check* / *on* / *true* / *yes* / *1* normalize to **`true`** for checkbox parameters.
- *disable* / *uncheck* / *off* / *false* / *no* / *0* normalize to **`false`** for checkbox parameters.
- For dropdown parameters, the user may pass either a label (exact match against an entry) or a 0-based numeric index; both are accepted by `set_mbdt_model_param` unchanged.
- If the user says "just fire it" / "run it" / "click it" for a `pushbutton`, no value is needed -- omit `selection`.
- Tag / group names are case-sensitive (they're MATLAB struct field names). Aliases above are user spellings only -- canonical forms must appear in `detect_mbdt_params` output.

## Applying the Change

The agent calls the `set_mbdt_model_param` MCP tool directly. Arguments are all primitive strings (no MATLAB handles or structs cross the boundary):

- **modelName** -- Simulink model name without extension. The tool loads the model if it is not already open.
- **platform** -- MBDT family identifier, case-insensitive, one of `s32k3`. Must match the platform whose parameter catalog contains the (group, tag) being set.
- **group** -- Parameter group name exactly as returned by `detect_mbdt_params({platform})` (top-level field of the returned struct, e.g. `PIL`, `Clocking`, `Build`).
- **tag** -- Parameter tag exactly as returned by `detect_mbdt_params({platform}).{group}` (leaf field name, e.g. `PIL_COMPort`, `PIL_Baudrate`).
- **selection** *(optional)* -- widget-type-dependent:
  - dropdown / combobox / popup: a 0-based numeric index passed as a string (e.g. `"1"`) **or** an entry label that matches exactly.
  - checkbox: one of `'on'`/`'off'`/`'true'`/`'false'`/`'yes'`/`'no'`/`'checked'`/`'unchecked'`, or `"0"`/`"1"`.
  - pushbutton: omit (or pass an empty string).

A representative reference invocation:

```
set_mbdt_model_param(modelName={mdl}, platform={family}, group={Group}, tag={Tag}, selection={selection})
```

Internally, the tool loads the model if needed, resolves `getActiveConfigSet(modelName)`, calls `detect_mbdt_params(platform)`, looks up the leaf at `(group, tag)`, builds the same `utils.HdlgWrapper` the live dialog uses, pushes the chosen value into the widget, and fires the leaf's `Callback`. The tool returns a struct with `modelName`, `platform`, `group`, `tag`, `widgetType`, `entries`, `selectedIndex`, and `selectedText` so the agent can confirm what was actually applied.

Raises:
- `set_mbdt_model_param:GroupNotFound` if `group` is not a top-level field returned by `detect_mbdt_params(platform)`. The error lists the available groups.
- `set_mbdt_model_param:TagNotFound` if `tag` is not a leaf of the resolved group. The error lists the available tags in that group.
- `set_mbdt_model_param:NoCallback` if the resolved leaf has no `Callback` defined (not a Hardware-pane field).
- `set_mbdt_model_param:UnsupportedType` if `Type` is not `pushbutton`, `combobox` / `dropdown` / `popup`, or `checkbox`.
- `set_mbdt_model_param:EmptyEntries` if a dropdown leaf produced no choices.
- `set_mbdt_model_param:BadIndex` / `set_mbdt_model_param:LabelNotFound` / `set_mbdt_model_param:BadSelection` for invalid dropdown selections.
- `set_mbdt_model_param:BadCheckbox` for invalid checkbox selections.
- `detect_mbdt_params:UnsupportedPlatform`, `detect_mbdt_params:XmlLookupFailed`, `detect_mbdt_params:XmlNotFound` for upstream discovery failures.

## Examples

| User says | What the agent does |
|---|---|
| "Set the PIL COM port to COM5 on `{model}`." | Calls `detect_mbdt_params` for the model's family; resolves to (`PIL`, `PIL_COMPort`); checks `Type` is a dropdown; passes `'COM5'` as `selection` to `set_mbdt_model_param` (which fails with `LabelNotFound` if the live callback's entries don't include `COM5` -- the agent then re-lists the live entries and asks). |
| "Change the PIL baudrate to 115200." | Resolves to (`PIL`, `PIL_Baudrate`); confirms `115200` is among the entries; calls `set_mbdt_model_param` with the label string. |
| "Enable the monitoring on this model." | Searches `Tag` and then `ToolTip` for "monitoring"; if a single checkbox leaf is found, normalizes "enable" to `true` and calls `set_mbdt_model_param` with `selection=true`; if multiple match, asks the user to pick from the candidate (group, tag, ToolTip) rows. |
| "Uncheck the option that controls FreeMASTER on serial." | Resolves via `ToolTip` substring; verifies the leaf is a checkbox; calls `set_mbdt_model_param` with `selection=false`. |
| "Fire the Update PIL button." | Resolves to the matching `pushbutton` leaf; calls `set_mbdt_model_param` with no `selection`. |
| "Set the CPU clock to 160 MHz." | Resolves to the `Clocking.CPU_Clock_in_MHz` leaf; if its `Type` is not one of {pushbutton, dropdown, checkbox} (it is typically a numeric edit), **stops** and explains this skill only drives those widget kinds -- suggests plain `set_param` via `evaluate_matlab_code`. |
| "What does the `PIL_Baudrate` parameter do?" | Out of scope -- this is a read query. The agent calls `detect_mbdt_params`, reads the `ToolTip` field, and reports it; does not invoke this skill. |
| "Change the target MCU to S32K358-Q172." | Out of scope -- redirects to `setting-mbdt-target-mcu`. |

## Guardrails

- **Never fabricate runtime values.** Group names, parameter tags, visible labels, tooltips, accepted dropdown entries, and current values are all read from `detect_mbdt_params` (and, for `EntriesType: callback`, from the live MBDT callback the tool invokes). If discovery fails or returns an empty list, stop and ask the user; never carry a tag, entry, or label from memory.
- **Never include implementation code in this SKILL.md.** Skills are prose. The reference invocation above is the only allowed inline form; multi-statement scripts, loops, conditionals, or pipelines belong in a tool, not here.
- **Never operate on a microcontroller without first verifying the MBDT family toolbox is installed.** Call `detect_matlab_toolboxes` and require an entry matching `Model-Based Design Toolbox for S32{family}...`. The `HardwareBoard` parameter or an `mbd_*` package being on the path is **not** proof. If the toolbox is missing, stop, report the product name, and ask. Never substitute a different family's parameter catalog -- `detect_mbdt_params` will silently fall back to whatever the unique installed family is, which is **not** acceptable here.
- **Always use `set_mbdt_model_param` to apply the change.** Do not write only the underlying `Storage` field with `set_param` or `codertarget.data.setParameterValue`; that bypasses the parameter's `Callback` and leaves any dependent fields stale (the live dialog never reconciles them either, so the model can end up incoherent in ways that only surface at code generation).
- **Do not call the parameter's `Callback` directly** via `feval(leaf.Callback, hObj, hDlg, fullTag, 'web')` or by constructing your own `utils.HdlgWrapper`. Callbacks expect a dialog wrapper that overrides `getComboBoxText` for the parameter's tag and that has the chosen text pushed via `setWidgetValue` -- `set_mbdt_model_param` does both. Hand-rolling them leaves callbacks reading stale values.
- **Never drive this change via `set_param(mdl, '{Storage}', ...)`** or via `codertarget.data.setParameterValue(hCS, '{tag}', ...)` as the primary action. Those APIs change the field but do not fire the MBDT callback; use `set_mbdt_model_param` so the callback runs.
- **Never use this skill to change the target MCU / hardware part / configuration template.** That action lives in the `Hardware_ProjectTemplate` pushbutton flow handled by `setting-mbdt-target-mcu`, which performs a full reconciliation (`Hardware_type`, `Configuration_tool`, `default_loc`, `{model}_Config` folder, `Clocking.cpuClockRateMHz`). Routing it through `set_mbdt_model_param` would skip that reconciliation.
- **Always pass `group` and `tag` exactly as returned by `detect_mbdt_params`.** They are MATLAB struct field names returned by `matlab.lang.makeValidName` from the registry XML and are case-sensitive. Do not transform them (lowercase, strip prefixes, replace underscores, ...) -- the tool's `GroupNotFound` / `TagNotFound` errors already list valid options, so on a mismatch propagate that list to the user instead of guessing.
- **Refuse near-miss matches.** If the user's wording does not match exactly one leaf by tag, label, or tooltip, list the candidates (group, tag, tooltip) and ask. Substring matching is acceptable for `Name` and `ToolTip` only when it yields a single candidate.
- **Dropdown selection is case-sensitive.** Pass the user's label through to `set_mbdt_model_param` unchanged; do not lowercase, trim, or normalize. The tool's `LabelNotFound` error already reports the actual valid entries -- propagate that list to the user instead of guessing the canonical casing.
- **Pushbutton parameters are write-only.** They have no "value" to read or compare before / after; the agent should report only that the callback was fired, not invent a before / after pair.
- **The model is changed in memory only.** `set_mbdt_model_param` does not save the model. If the user wants the change to persist on disk, the agent must call `save_system({model})` separately and tell the user that it did so. If the user did not ask to save, the change lives only in the running Simulink session -- say so explicitly when reporting.

## Validation loop

1. After `set_mbdt_model_param` returns, check the returned struct: `selectedText` must match the intended value for dropdowns/checkboxes; for pushbuttons confirm the call returned without error.
2. If the returned `selectedIndex` or `selectedText` does not match the intended selection, re-read `detect_mbdt_params` to obtain the current live entries and report the discrepancy to the user.
3. If any `set_mbdt_model_param:*` error is raised, surface the error message verbatim (it includes the valid groups/tags/entries) -- do not retry with a fabricated value.
4. Report the resolved (group, tag), the leaf's `ToolTip`, and the confirmed new value. If the model was not saved, explicitly tell the user the change is in memory only.

## References

- `detect_mbdt_params` -- MCP tool that returns the live parameter catalog for a given MBDT platform. Single source of truth for group names, tag names, widget types, and dropdown entries.
- `set_mbdt_model_param` -- MCP tool that applies the change by driving the MBDT callback the same way the live dialog does.
- `setting-mbdt-target-mcu` -- for changing the target MCU / hardware part / configuration template (out of scope for this skill).
- `refreshing-mbdt-com-ports` -- use instead of this skill when the parameter is a serial / COM port dropdown (requires a Refresh pushbutton to be fired first).

