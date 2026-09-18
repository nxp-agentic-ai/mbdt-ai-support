---
name: setting-mbdt-target-mcu
description: "Use when the user asks to change, switch, select, set, or list the target MCU, processor, hardware part, device variant, or Hardware Configuration Template of an NXP MBDT Simulink model -- including picking a specific S32K3 device or board template, switching between S32CT and EB tresos tool configurations, or querying which templates are available. Drives `set_mbdt_device`, handles the processor-changed `warndlg` modal with user approval, and verifies the change both in memory and on disk. Do not use for Configuration Parameters / Hardware Implementation pane fields such as clock, PIL, scheduler, or build settings (-> setting-mbdt-model-params), slbuild / code generation / flash / deploy (-> building-mbdt-model), PIL or FreeMASTER COM port refresh (-> refreshing-mbdt-com-ports), opening S32DS projects (-> managing-mbdt-s32ds-project), or configuring driver blocks like ADC, CAN, PWM (-> configuring-mbdt-blocks)."
license: LA_OPT_Online Code Hosting NXP_Software_License
metadata:
  author: NXP
  version: "1.0.0"
  product: nxp-mbdt
  tags: '[mbdt, target-mcu, configuration-template]'
---

# NXP MBDT -- Change Hardware Configuration Template

The MBDT dropdown handler `selectConfiguration` calls
`hDlg.getComboBoxText('Tag_ConfigSet_CoderTarget_Hardware_SelectDefaultLoc')` --
which returns **empty** when invoked programmatically (the underlying combobox value is only synced on a real user click). So the simple "set the widget and fire the callback" approach silently does nothing useful.

When the processor changes, the toolbox raises a modal `warndlg` and blocks on `waitfor(mydlg)`. Closing that dialog too eagerly (while `msgbox` is still inside `textwrap()`/layout) aborts the caller **before** `set_param('Hardware_type', ...)` runs, leaving the model in an inconsistent state. The watcher in this skill avoids that race by waiting until the dialog is fully constructed, printing its content, and then waiting for user acknowledgement before the dialog can be released.

Additionally, the MBDT cross-tool cleanup paths (e.g. leaving EB tresos for S32CT) can silently fail because internal functions like `mbd_s32k3.common.nxp.utils.ebt.list_ebt_components` may return no outputs -- the toolbox's outer `try/catch` then swallows the error and leaves the configset in its **previous** state. The skill detects this failure mode and either errors loudly or, if the model is dirty, performs a clean reload first to bypass the brittle paths.

## When to Use

Use this skill whenever the user wants to:

- List the configuration templates available in the **Hardware -> Select Configuration Template** dropdown of an NXP MBDT model (S32K3).

- Programmatically **switch** the template (e.g. switch processor, switch S32CT <-> EB tresos).
- Have the **warning dialog** that appears when the processor/core changes be **shown to the user (message printed)**. The dialog title and full message text must be relayed to the user before any button is clicked. **The agent must not dismiss the dialog on its own.** Clicking OK is only permitted after the user has explicitly acknowledged the warning or has stated that non-interactive operation is acceptable for this session -- *without* corrupting the toolbox call that emitted it.
- Have the change **verified in-memory AND on disk** so silent failures are caught immediately.

## When NOT to Use

- The user wants to **set a non-template Hardware Implementation parameter** (PIL port, clocking, build options, ...) -> use `setting-mbdt-model-params`.
- The user wants to **open the external configuration tool** (S32CT / EB tresos) -> use `opening-mbdt-config-tool`.
- The user wants to **open the S32 Design Studio project** -> use `managing-mbdt-s32ds-project`.

## Workflow

### 1. List available templates

```matlab
cells = mbd_s32k3.common.nxp.ui.getDefaultConfigurationTemplates();
```

Replace `mbd_s32k3` with the platform the model targets. Each MCU appears as two rows: `... S32 Config Tool` and `... EB tresos`. Custom boards appear with a `Custom: ` prefix.

### 2. Apply a template

Call the bundled helper, passing the model name and the **exact** dropdown entry the user picked. See [Applying the Change](#applying-the-change) for the signature and the step-by-step internal flow.

### 3. Verify (manually, if you want extra reassurance)

```matlab
hObj = getActiveConfigSet('{modelName}');
codertarget.data.getParameterValue(hObj, 'Hardware.SelectDefaultLoc')
codertarget.data.getParameterValue(hObj, 'Hardware_type')
codertarget.data.getParameterValue(hObj, 'Configuration_tool')
codertarget.data.getParameterValue(hObj, 'default_loc')
```

All four should agree with the requested template. (The helper already does this for you internally and on disk.)

## Defaults and Disambiguation

- The target Simulink model **must be loadable**. `set_mbdt_device` will `load_system` it automatically if it is not already loaded.
- The MBDT toolbox for the corresponding platform must be on the MATLAB path (the example folder normally does this via a `startup` step or by running the MBDT installer).
- The **Configuration Parameters** dialog does **not** need to be open. If it is open, the helper will also update the visible widget so the GUI is in sync.
- Switching `S32 Config Tool` <-> `EB tresos` triggers extra side effects (removal of the existing `*Config` folder, prompt for an EB tresos installation path). The watcher handles the warning, but if EB tresos is being selected for the first time on this machine the toolbox may also raise an EB-path file picker that is **not** a `Msgbox_*` -- that one must still be handled interactively.
- Changing the processor irreversibly deletes the existing `*_Config` folder near the model. Warn the user before doing it on important models.

## Applying the Change

Call the bundled helper, passing the model name and the **exact** dropdown entry the user picked. Always pass `'Save', true` so the change is persisted to disk -- the underlying function's own default is `false`, so the skill must request the save explicitly:

```matlab
% e.g. evaluate_matlab_code (MCP) or run from the MATLAB Command Window
set_mbdt_device('s32k3xx_dio_s32ct', 's32k3', 'S32K344-Q172 S32 Config Tool', 'Save', true);
```

Pass `'Save', false` only when the user explicitly says not to save -- in that case tell the user the change lives in memory only.

Signature:

```matlab
set_mbdt_device(modelName, templateEntry, ...
                'Save',        true | false, ...     % default true
                'Verify',      true | false, ...     % default true
                'CleanReload', true | false | 'auto')% default 'auto'
```

What it does, in order:

1. Adds this skill's folder to the MATLAB path (so the watcher is callable).
2. Auto-detects the MBDT platform by which `mbd_s32*.common.nxp.ui.getDefaultConfigurationTemplates` resolves on the path.
3. Loads the model if it is not already loaded.
4. Resolves the dropdown entry to its `.mex` / TresosProject path via `{platform}.common.nxp.ui.getDefaultConfigurationTemplates(entryName)`.
5. Snapshots the previous `Hardware_type` / `Configuration_tool`.
6. **`'CleanReload' = 'auto'`**: if the model is dirty AND we are switching across `S32 Config Tool <-> EB tresos`, runs `close_system(model,0)` followed by `load_system(model)`. This bypasses the brittle MBDT cleanup paths that can swallow errors.
7. Locates any open Configuration Parameters dialog (so the on-screen widget can be synced too).
8. Starts a timer-based watcher on `groot` that:
   - Finds new figures whose `Tag` starts with `Msgbox_`.
   - Waits until the dialog is **fully built** (HandleVisibility=='callback' AND Visible=='on').
   - Prints title + message + button list with the `[WatchedDialog]` prefix.
   - Prints the button list. If there is exactly **one** button and the user has given prior approval for non-interactive operation, fires its `Callback` and closes the figure (releasing `waitfor`). Otherwise, waits for the user to acknowledge before proceeding.
9. Calls `{platform}.common.nxp.ui.selectConfiguration` via the **Browse** branch (tag `Tag_ConfigSet_CoderTarget_browse_config`) -- this branch takes the path explicitly, so it does **not** depend on `getComboBoxText`.
10. Forces the dropdown's displayed value to match (so the GUI is consistent) using `codertarget.data.setParameterValue` and `hDlg.setWidgetValue` if the dialog is open.
11. Stops + deletes the watcher in an `onCleanup`.
12. **`'Verify' = true`** (default): re-reads `Hardware_type` and `Configuration_tool` and **throws** `set_mbdt_device:verifyFailed` if they don't match the request -- catching the silent-failure case where the toolbox's outer try/catch swallowed an internal error.
13. **`'Save' = true`** (default): runs `save_system(model)` and then grep-verifies the `.mdl`/`.slx` on disk for the expected `Hardware_type` and `Configuration_tool` strings. Throws `set_mbdt_device:diskMismatch` if either is missing.

If anything goes wrong, the function errors loudly -- it never reports a misleading "success".

## Examples

| User says | Action |
|---|---|
| "Change the configuration template to `S32K344-Q172 S32 Config Tool`." | `set_mbdt_device(model, family, 'S32K344-Q172 S32 Config Tool', 'Save', true)` after verifying the entry is in `get_mbdt_toolbox(family, 'devices')`. |
| "Switch this MBDT model from S32CT to EB tresos." | Resolve the matching `... EB tresos` entry from the live device list, then `set_mbdt_device(model, family, '{entry} EB tresos', 'Save', true)`; the watcher prints `[WatchedDialog]` with the warning text -- relay it to the user and wait for acknowledgement before the dialog is dismissed. |
| "List the entries in Hardware -> Select Configuration Template." | Read-only: return the entries from `get_mbdt_toolbox(family, 'devices')` (or `{platform}.common.nxp.ui.getDefaultConfigurationTemplates()`); do not call `set_mbdt_device`. |
| "Apply the S32K312MINI custom board template but don't save." | `set_mbdt_device(model, family, 'Custom: S32K312MINI-EVB EB tresos', 'Save', false)`; tell the user the change lives in memory only. |
| "Switch part and confirm the warning for me." | Same `set_mbdt_device` call; the bundled watcher prints the `[WatchedDialog]` message. **Relay the dialog title and full message text to the user first.** Clicking OK is only permitted after the user has explicitly acknowledged the warning or has stated that non-interactive operation is acceptable for this session. This is a required human approval step that must not be skipped. |

## Guardrails

- **Never fabricate values.** Do not invent, memorize, or guess device names, board names, processor names, block names, library paths, dropdown selections, peripheral names, or any other catalog entry. Always call `get_mbdt_toolbox(family, 'devices')` first and accept only entries it returns. If the discovery tool is unavailable, fall back to a generic tool (e.g. `evaluate_matlab_code` against the relevant `mbd_*` package) or ask the user -- never fabricate a value from memory.
- **Never operate on a microcontroller without first verifying the MBDT family toolbox is installed.** Before any device-specific or board-specific action, call the MCP tool `detect_matlab_toolboxes` (or, as a MATLAB-side fallback, run `ver` with no arguments and inspect the `Name` field) and require an entry matching `Model-Based Design Toolbox for S32{family}...` (e.g. `Model-Based Design Toolbox for S32K3 Series`). A family identifier appearing on the `set_mbdt_device` enum is **not** proof of installation. `get_mbdt_toolbox` returning data is **not** proof of installation either -- it is known to fall back silently to a different family's catalog when the requested family is missing. If the toolbox is not installed, stop, report the missing toolbox by its product name (e.g. `Model-Based Design Toolbox for S32K3 Series`), and ask the user to install it or pick a family that is installed -- never fabricate a device name, never substitute a different family's catalog, never apply a board the platform doesn't expose.
- **Never drive the template switch by hand instead of through `set_mbdt_device`.** Do not set the hardware type / configuration-tool parameters yourself, and do not `close`/`delete` the processor-changed `warndlg` manually. The programmatic combobox value does not sync the way a real user click does, and dismissing the modal too early aborts the caller before the hardware type is committed, leaving the model inconsistent. `set_mbdt_device` owns the switch, the dialog handling, and the in-memory-plus-on-disk verification -- it is the single entry point.

## Validation loop

1. After `set_mbdt_device` returns, confirm it printed `[set_mbdt_device] SUCCESS: {prev} -> {new}` and `[set_mbdt_device] Saved to disk and verified: {path}`. Any other outcome is a failure -- surface the error verbatim.
2. Verify the four in-memory parameters agree with the requested template: `Hardware.SelectDefaultLoc`, `Hardware_type`, `Configuration_tool`, and `default_loc`. If `set_mbdt_device:verifyFailed` was raised, do not retry; report the discrepancy to the user.
3. If `set_mbdt_device:diskMismatch` was raised, the save succeeded but the grep check failed -- ask the user to inspect the `.slx` on disk.
4. If the `[WatchedDialog]` prefix appears in the output, relay the dialog title and message to the user. Confirm that the OK button was clicked only after the user acknowledged the warning or approved non-interactive operation. Check the log confirms the dialog was handled and `waitfor` was released.
