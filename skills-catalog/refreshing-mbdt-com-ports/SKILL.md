---
name: refreshing-mbdt-com-ports
description: "Use whenever the user asks to read, set, change, pick, refresh, or list serial COM ports on an NXP MBDT-targeted Simulink model (S32K3) -- specifically the PIL COM port, External Mode COM port, or FreeMASTER serial port found under Configuration Parameters -> Hardware Implementation -> Target hardware resources; this skill is mandatory over `setting-mbdt-model-params` for every COM port field because the Refresh pushbutton must be clicked before each read or write to avoid a blocking modal popup that halts autonomous agents. Not for other Hardware Implementation parameters (use `setting-mbdt-model-params`); not for MCU or core selection (use `setting-mbdt-target-mcu`); not for block-level UART, LIN, or SPI peripheral config (use `configuring-mbdt-blocks`)."
license: LA_OPT_Online Code Hosting NXP_Software_License
metadata:
  author: NXP
  version: "1.0.0"
  product: nxp-mbdt
  tags: '[mbdt, com-port, pil, serial]'
  depends_on: '[setting-mbdt-model-params]'
---

# Refreshing the MBDT COM Port List Before a PIL or External-Mode COM Port Change

Use this skill whenever the user wants to **read, set, or change a serial / COM / UART port** on an NXP MBDT-targeted Simulink model -- most commonly the **PIL COM port**, the **External Mode COM port**, or the **FreeMASTER serial port** on the **Configuration Parameters -> Hardware Implementation -> Target hardware resources** pane.

The MBDT dropdown for these fields caches its entry list inside the running MATLAB session and inside any open Configuration Parameters dialog. That cache is **not** refreshed by reading `detect_mbdt_params`, nor by calling `set_mbdt_model_param` against the COM port field directly -- it is refreshed only by firing the same **Refresh** pushbutton the live Configuration Parameters dialog exposes. That pushbutton lives next to every serial-port dropdown on the pane; its callback re-enumerates the host's serial ports and replaces the dropdown's entry list with the fresh result.

**If the agent writes the COM port field without firing Refresh first, or writes a value that is not in the just-refreshed entries, MBDT shows a blocking modal popup (*"The COM ports list has been changed and the selection canceled! Please redo the selection using the new entries."*). The popup pauses MATLAB until a human clicks it -- which is fatal for autonomous agent execution.** This skill exists to make that popup impossible to trigger.

Valid serial-port entries are **always retrieved at runtime** by firing the Refresh pushbutton through `set_mbdt_model_param` and then reading the resolved leaf's live `Entries` via `detect_mbdt_params`. The change itself is performed by handing off to the `setting-mbdt-model-params` skill, which dispatches to the `set_mbdt_model_param` MATLAB tool.

## When to Use

- The user asks to **set / change / edit / configure / pick / select** any of:
  - the **PIL COM port** (a leaf under the `PIL` group, typically named `PIL_COMPort` -- verify via `detect_mbdt_params`).
  - the **External Mode COM port** (a leaf under the `ExternalMode` group -- verify via `detect_mbdt_params`).
  - the **FreeMASTER serial port** or any other Hardware-Implementation pane field whose `EntriesType` callback enumerates host serial ports.
  - any field whose visible label or `ToolTip` contains *"COM"*, *"serial port"*, *"UART"*, or *"port"* on the Target Hardware Resources pane.
- The user reports the *"COM ports list has been changed and the selection canceled"* popup and wants to retry.
- The user just plugged in or unplugged a USB-serial adapter, reassigned a COM number in Device Manager, or rebooted the probe -- and wants to use a newly-available port.
- The user asks "what COM ports are available?" on an MBDT model (read query, but the read MUST still come from a freshly-fired Refresh button, not from cache).

## When NOT to Use

- The user asks to change a **non-serial** Hardware-Implementation parameter (CPU clock, baud rate, peripheral mux, ...) -> use `setting-mbdt-model-params` directly; no refresh is required.
- The user asks to **open the external configuration tool** (S32CT / EB tresos) -> use `opening-mbdt-config-tool`.
- The user asks to **change the target MCU / processor / hardware part** -> use `setting-mbdt-target-mcu`.
- The user asks the agent to **enumerate host serial ports outside of any MBDT model context** (e.g. "what COM ports does Windows see right now?") -> call `serialportlist("available")` via `evaluate_matlab_code` directly; this skill is specifically about the MBDT dropdown's view of the port list, which is what governs what the model will accept.

## Workflow

1. **Identify the model and the target serial-port parameter.** Resolve the user's wording to a concrete (group, tag) pair on the user's MBDT-targeted Simulink model. If the user named only the field (e.g. "the PIL COM port"), look in the `PIL` group; if "External Mode COM port", look in the `ExternalMode` group; for FreeMASTER-over-serial, locate the matching leaf on the Hardware-Implementation pane. If unsure or if multiple candidates exist, list the candidates and ask -- never guess.

2. **Detect the MBDT platform** for the model -- one of the family keys accepted by `get_mbdt_toolbox` (`s32k3`). Use this family identifier for every subsequent discovery call.

3. **Discover the Refresh pushbutton** for the target serial-port group by calling `detect_mbdt_params({family})`. Inside the same group as the COM port leaf (e.g. `PIL`, `ExternalMode`), locate the **pushbutton** leaf whose visible `Name` or `ToolTip` is "Refresh" (or contains the word *"refresh"*). Its `Tag` is the canonical identifier -- accept whatever the live catalog reports; do not hard-code a tag name. Verify the leaf's `Type` is `pushbutton`. If no Refresh pushbutton can be found in the group, stop and report -- never attempt to write the COM port field on a group that does not expose a Refresh button, because the only way to defeat the cache on that pane is the pushbutton.

4. **Fire the Refresh pushbutton -- mandatory, live, in this turn, every single time.** Call `set_mbdt_model_param` with `(modelName, family, group, refreshTag)` and **no `selection` argument** (pushbuttons take no value). This invokes the same callback the live dialog's Refresh button does; the callback re-enumerates the host's serial ports and replaces the dropdown's cached entry list with the fresh result. Do not skip this step. Do not substitute `detect_mbdt_params` for it -- `detect_mbdt_params` reads the registry XML and the leaf's `Entries` expression as last cached; it does **not** fire the callback that defeats the cache.

5. **Read the now-refreshed live entries** by calling `detect_mbdt_params({family})` again. Locate the COM port leaf in the same group. Its `Entries` field (or, for `EntriesType: callback`, the entries the callback now returns) reflects the fresh re-scan. This is the **only** valid source of truth for the rest of this turn. Do not reuse a port list from any earlier turn, from any earlier `detect_mbdt_params` call, from any earlier `set_mbdt_model_param` result, or from any open Configuration Parameters dialog.

6. **Resolve the user's intended port against the live entries:**
   - If the user named a specific port and it appears in the live entries, proceed to step 7.
   - If the user named a specific port and it does **not** appear in the live entries, **stop**. Show the live entry list verbatim, explain that the named port is not currently available, and ask the user to pick from the live list (or fix their hardware and re-invoke the skill). **Do not** call `setting-mbdt-model-params` with the unavailable port -- doing so triggers the blocking popup.
   - If the user said "set it to whatever is available" and exactly one entry is present, proceed with that one.
   - If the user said "whatever is available" but multiple entries are present, list them and ask.
   - If the live entry list is empty, stop and report -- no COM port is currently available on the host; suggest checking Device Manager. **Do not** retry firing Refresh; an empty list means there is genuinely nothing connected.

7. **Hand off to `setting-mbdt-model-params`** to write the COM port field with the resolved entry. That skill owns the actual callback firing for the write. Pass the canonical (group, tag) pair for the COM port leaf (not for the Refresh pushbutton) and the selected label string.

8. **Report** briefly: model name, the resolved COM port (group, tag) pair, the Refresh pushbutton (group, tag) pair that was fired, the live entry list returned after the refresh, the entry that was selected, and an explicit note that the entries were re-discovered live via the Refresh pushbutton (not pulled from cache).

## Defaults and Disambiguation

- "PIL COM port", "PIL serial port", "the PIL port" -> resolve to the COM port leaf in the `PIL` group; the matching Refresh pushbutton is the `Refresh`-typed pushbutton in the same `PIL` group.
- "External Mode COM port", "extmode COM port", "the XCP port", "the monitoring port" -> resolve to the COM port leaf in the `ExternalMode` group; the matching Refresh pushbutton is in the same `ExternalMode` group.
- "FreeMASTER COM port", "the FM serial port" -> if the model exposes a FreeMASTER-over-serial dropdown on the Hardware-Implementation pane, resolve to that leaf via `detect_mbdt_params` and look for a Refresh pushbutton in the same group. If no Refresh pushbutton exists in that group, stop and tell the user this skill cannot safely write the field.
- If the user says "the COM port" with no qualifier and the model has more than one serial-port dropdown, **stop and ask** which one.
- "COMx" labels are case-insensitive on Windows but are presented in uppercase by MBDT's callback. Pass them to `setting-mbdt-model-params` exactly as they appear in the live entry list.

## Applying the Refresh

The refresh is performed by firing the Refresh **pushbutton** the live Configuration Parameters dialog exposes, via the existing `set_mbdt_model_param` MATLAB tool. Two separate calls are involved per invocation of this skill:

**Call 1 -- fire the Refresh pushbutton.** Arguments to `set_mbdt_model_param`:

- **modelName** -- Simulink model name (no extension). The tool loads the model if it is not open.
- **platform** -- MBDT family identifier matching the model's coder target. Case-insensitive. One of `s32k3`.
- **group** -- the parameter group containing the COM port field (e.g. `PIL`, `ExternalMode`).
- **tag** -- the canonical `Tag` of the Refresh pushbutton leaf in that group, as returned by `detect_mbdt_params({platform})`. Do not hard-code; read it from the catalog.
- **selection** -- *omitted* (pushbuttons take no value).

This call fires the pushbutton's callback, which re-enumerates the host's serial ports and replaces the dropdown's cached entries.

**Call 2 -- read the refreshed entries and write the COM port.** Re-call `detect_mbdt_params({platform})`, find the COM port leaf in the same group, and check its `Entries` (or invoke the leaf's live `Entries` callback) to obtain the freshly-refreshed list. Then hand off to `setting-mbdt-model-params`, which internally calls `set_mbdt_model_param` with the COM port leaf's (group, tag) and the resolved entry label.

The two calls **must** happen in this order, in the same turn. There is no shortcut: skipping call 1, or running call 2 against a list captured before call 1, recreates the blocking popup.

Raises:
- `set_mbdt_model_param:GroupNotFound` / `:TagNotFound` -- if the pushbutton or COM port leaf cannot be resolved against the live catalog. Stop and report; do not retry with a fabricated tag.
- `set_mbdt_model_param:UnsupportedType` -- if the leaf the agent thought was the Refresh pushbutton turns out to be a different widget kind. Stop and re-discover; do not coerce.
- All errors raised by `setting-mbdt-model-params` (and underneath it `set_mbdt_model_param`) for the write -- in particular `LabelNotFound` and `BadSelection`. **Treat these as a contract violation**: it means call 2 ran against a port not in the just-refreshed list, which should be impossible if step 6 was honoured. Stop, surface the live entries to the user, and ask them to pick again.

## Examples

| User says | What the agent does |
|---|---|
| "Set the PIL COM port to COM5 on `{model}`." | Discovers the PIL group's Refresh pushbutton via `detect_mbdt_params`; fires it via `set_mbdt_model_param`; re-reads `detect_mbdt_params` to get the live entries; if `COM5` is present, hands off to `setting-mbdt-model-params`; if not, surfaces the live entry list and stops. |
| "Set the PIL COM port to whatever is available." | Same as above; if the live entries have exactly one port, proceeds with it; if multiple, asks; if none, reports the empty list. |
| "I just plugged in the FTDI cable, set the PIL port to that one." | Fires the Refresh pushbutton (no reuse of any earlier list); identifies the new port in the live entries; hands off to `setting-mbdt-model-params`. |
| "Set the External Mode COM port to COM7." | Discovers the ExternalMode group's Refresh pushbutton; fires it; re-reads entries; proceeds as for PIL. |
| "What COM ports does the model see right now?" | Fires the Refresh pushbutton; re-reads entries; reports the live list. Does NOT report a cached list from earlier in the conversation. |
| "MBDT just popped up a dialog saying the COM ports list changed -- redo it." | Acknowledges the popup; **fires the Refresh pushbutton** (the popup was caused by skipping this step); re-reads entries; hands off to `setting-mbdt-model-params` with the entry the user originally wanted (or asks if it is no longer available). |
| "Change the baud rate to 115200." | Out of scope -- baud rate is not a serial-port enumeration. Skip the refresh; go directly to `setting-mbdt-model-params`. |
| "Change the target MCU to S32K388-Q289." | Out of scope -- redirects to `setting-mbdt-target-mcu`. |
| "What ports does Windows see?" | Out of scope of the MBDT dropdown -- call `serialportlist("available")` via `evaluate_matlab_code` directly. |

## Guardrails

- **Never fabricate runtime values.** Parameter group names, tags, visible labels, tooltips, and -- above all -- the live serial-port entries are read from `detect_mbdt_params` and from the just-fired Refresh pushbutton callback. If discovery fails or the live list is empty, stop and ask the user; never carry a COM port name, a (group, tag) pair, a Refresh-pushbutton tag, or an entry label from memory, from a previous turn, or from training data.
- **Never include implementation code in this SKILL.md.** Skills are prose. The reference invocations above are the only allowed inline form; multi-statement scripts, loops, conditionals, or pipelines belong in a tool, not here.
- **Never write any `COM*` field without first firing the Refresh pushbutton in the same turn.** This is the absolute rule. `detect_mbdt_params` alone does **not** refresh the dropdown's cache; only the pushbutton callback does. Writing a port to the COM port field before the cache has been refreshed -- *or* writing a port that is not in the just-refreshed entries -- triggers a blocking modal popup (*"The COM ports list has been changed and the selection canceled! Please redo the selection using the new entries."*) that pauses MATLAB until a human clicks OK. **That popup is fatal for autonomous agents**: the MCP tool that issued the write blocks until timeout, the agent cannot dismiss it programmatically, and the model is left in an inconsistent state. There is no acceptable scenario in which the COM port field is written before the Refresh pushbutton has been fired in the same turn.
- **Never reuse a cached COM port entry list.** Every invocation of this skill MUST fire the Refresh pushbutton in the current turn, even if the same skill ran moments ago and even if the agent has an `entries` value from an earlier `set_mbdt_model_param` result. There is no acceptable optimization. The whole point of this skill is to defeat the cache.
- **Never name a COM port from memory.** If the user did not name a specific port, do not invent one based on what was valid earlier -- always read it from the live entry list returned by the post-refresh `detect_mbdt_params` call.
- **Always hand off to `setting-mbdt-model-params` to write the COM port.** Do not write the COM port `Storage` field directly via `set_param` or `codertarget.data.setParameterValue`; that bypasses the MBDT callback that owns the consistency check and produces the popup at the worst possible time (e.g. during a build).
- **Do not call the Refresh pushbutton's underlying callback directly** via `feval('mbd_{family}.common.nxp.ui.refresh_pil_ext_ui', ...)` or any equivalent. The callback expects the dialog wrapper that `set_mbdt_model_param` constructs; hand-rolling it leaves the dropdown in a half-refreshed state where the entries appear updated but the dialog's internal cache disagrees -- which still produces the popup on the next write.
- **Never substitute another family's Refresh pushbutton.** The Refresh callback is family-specific (e.g. `mbd_s32k3.common.nxp.ui.refresh_pil_ext_ui` vs equivalents on other families). Always verify the family with `get_mbdt_toolbox(family, 'devices')` and discover the pushbutton's tag for *that family's* catalog before firing.
- **Never operate without first verifying the MBDT family toolbox is installed.** Before firing the Refresh pushbutton or reading COM port entries, call `detect_matlab_toolboxes` (or `ver` as a fallback) and require a `Model-Based Design Toolbox for S32{family}...` entry. A family appearing on a tool's enum is not proof, and `detect_mbdt_params` returning data is not proof -- it can silently fall back to another family's catalog. If the toolbox is missing, stop, name the product, and ask the user; never substitute a different family's catalog.
- **Never retry on an empty live entry list.** If the just-refreshed entry list is empty, the host has no available serial ports; reporting "no ports available" is the correct outcome. Re-firing the Refresh pushbutton will not conjure one.
- **Treat `set_mbdt_model_param:LabelNotFound` or `:BadSelection` on the write call as a contract violation, not a retry trigger.** If the resolution step (workflow step 6) was honoured, the resolved port is guaranteed to be in the live entries. If the write nonetheless fails with one of these errors, it means the cache invariant has been broken by something outside this skill's control (e.g. the user yanked the cable mid-turn). Stop, surface the freshly-refreshed entries to the user, and ask them to pick again -- do **not** silently retry, because the next write attempt may produce the blocking popup.
- **Do not present a stale list to the user.** When asking the user to pick from available ports, present only the entries returned by the post-refresh `detect_mbdt_params` call. Never combine, merge, or augment with entries the agent saw earlier in the conversation -- the older entries may include ports that no longer exist on the host.
- **Do not save the model unless the user asked.** This skill (via `setting-mbdt-model-params`) changes the model in memory only. The COM port change lives only in the running Simulink session unless the user explicitly asks for `save_system`.

## Validation loop

1. After firing the Refresh pushbutton, verify `set_mbdt_model_param` returned without error before reading the refreshed entries.
2. After re-calling `detect_mbdt_params`, confirm the COM port leaf's `Entries` list is non-empty. If it is empty, stop and report -- do not attempt to write the COM port field.
3. After handing off to `setting-mbdt-model-params`, verify the returned `selectedText` matches the intended port label.
4. If `set_mbdt_model_param:LabelNotFound` or `:BadSelection` is raised on the write, treat it as a contract violation: surface the fresh entry list to the user and ask them to pick again.

## References

- `setting-mbdt-model-params` -- the skill that owns the actual write of the COM port field after refresh.

