---
name: opening-mbdt-config-tool
description: "Use when the user wants to open, launch, start, or invoke the external configuration tool paired with an NXP MBDT Simulink model -- S32CT, S32 Configuration Tools, S32DS Config Tools, or EB tresos -- including clicking or reproducing the Hardware Implementation pane 'Open'/'Configure' button, loading a .mex or _TresosProject file into the running tool, or navigating to a specific peripheral module (Adc, Can, Dio, Pwm, Spi, Lin, Gpt, Icu, Mcu, Port, etc.) inside that tool. Covers S32K3 targets. Out of scope: setting Configuration Parameters or Hardware Implementation pane fields (-> setting-mbdt-model-params); changing target MCU or derivative (-> setting-mbdt-target-mcu); building, generating code, or flashing (-> building-mbdt-model); opening S32DS IDE for the generated C project (-> managing-mbdt-s32ds-project); configuring MBDT driver blocks inside Simulink canvas (-> configuring-mbdt-blocks)."
license: LA_OPT_Online Code Hosting NXP_Software_License
metadata:
  author: NXP
  version: "1.0.0"
  product: nxp-mbdt
  tags: '[mbdt, config-tool, s32ct, tresos]'
---

# Opening the NXP MBDT External Configuration Tool

Use this skill to launch the **external configuration tool** that is paired with a Simulink model targeting any NXP MBDT platform, with the model's *per-project* configuration already loaded -- exactly as if the user had clicked the **Open** / **Configure** button under *Configuration Parameters -> Hardware Implementation -> Target hardware resources*.

The skill is **platform-agnostic**: it works with every NXP MBDT toolbox installed on the machine (e.g. `Model-Based Design Toolbox for S32K3 Series`, `... for S32M2xx Series`, `... for S32ZE Series`, ...). It detects the active platform from the model's coder target at runtime; you do **not** hard-code the platform.

The tool launched is chosen automatically based on the model's `Configuration_tool` setting:

- `S32 Config Tool` -> launches **S32 Configuration Tools** (`tools.exe`) and loads `{model}Config.mex` next to the model.
- `EB tresos` -> launches **EB tresos** and opens `{model}_TresosProject\` next to the model.

## When to Use

- The user asks to **open / launch / start / show / edit** the *external configuration tool*, *S32CT*, *S32 Config Tool*, *S32DS Config Tools*, *EB tresos*, *the configuration*, or *the peripheral configuration* for any NXP-targeted Simulink model.
- The user asks to *jump to a specific peripheral configuration* (Adc, Can, Dio, Pwm, Spi, Uart, Mcu, Port, Mcl, etc.).
- The user just changed the target MCU/board (often via the `setting-mbdt-target-mcu` skill, when present) and now wants to inspect or edit the regenerated configuration.

## When NOT to Use

- The user asks to open the **default template** distributed by MBDT (the read-only one under `{MBDT_TBX}\devices\...`). That is a different action; use `mbd_{platform}.common.nxp.ui.open_configuration` instead. This skill always opens the **per-model** project.
- The user asks to open **S32 Design Studio** (the IDE). Use `mbd_{platform}.common.nxp.ui.openS32DSProject` for that.
- The user wants to *change the target MCU / board* -- use the corresponding `setting-mbdt-target-mcu` skill.

## Workflow

1. **Identify the model.** If the user did not name one, use the currently focused MBDT-targeted Simulink model. If multiple are open, ask which one.

2. **Detect the platform** from the model's coder target. The platform string is a token like `s32k3`. Derive it once and reuse:

   ```matlab
   hCS = getActiveConfigSet(mdl);
   stf = get_param(hCS, 'SystemTargetFile');
   ctd = get_param(hCS, 'CoderTargetData');           % MBDT data struct
   board = get_param(hCS, 'HardwareBoard');           % e.g. 'NXP S32K3xx'
   % Resolve the platform package name 'mbd_{platform}' from the active toolbox:
   tbxPath  = which(['mbd_s32k3.common.nxp.utils.open_config_tool']);  % example probe
   platform = regexp(which('mbd_s32k3.common.nxp.utils.open_config_tool'), ...
                     '(?<=mbd_)\w+(?=\.)', 'match', 'once');
   ```

   In practice, list the available `mbd_*` packages and pick the one whose `HardwareBoard` matches the model's:

   ```matlab
   pkgs = meta.package.fromName('').PackageList;
   mbdtPkgs = pkgs(startsWith({pkgs.Name}, 'mbd_'));
   ```

   When in doubt, ask the user (rare).

3. **Read the active config set** to determine which configuration tool the model uses:

   ```matlab
   tool = codertarget.data.getParameterValue(hCS, 'Configuration_tool'); % 'S32 Config Tool' | 'EB tresos'
   ```

4. **Resolve the component to focus on** (optional). Map the user's wording to one of the MBDT component names (the set varies slightly per platform but always includes these):

   `Adc`, `Can`, `Dio`, `Gpt`, `Icu`, `Mcl`, `Mcu`, `Port`, `Pwm`, `Spi`, `Uart`.

   - If the user does not name a peripheral, default to **`Mcu`** (always present in any MBDT project; safe sentinel that the S32CT helper accepts).
   - The helper expects the **first letter capitalised**, e.g. `Mcu`, not `mcu`.

5. **Make the model the current system** before invoking the MBDT helper (it reads `gcs` to distinguish library blocks from model blocks):

   ```matlab
   load_system(mdl);
   set_param(0, 'CurrentSystem', mdl);
   ```

6. **Invoke the same MBDT callback the UI uses.** Do **not** spawn `tools.exe` / EB tresos directly -- go through the platform's MBDT helper so it regenerates the per-project artefact if missing, handles the *"already open"* case, and (for S32CT) issues the HTTP request to focus on the requested peripheral view.

   ```matlab
   feval(['mbd_' platform '.common.nxp.utils.open_config_tool'], hCS, hCS, component);
   ```

   Equivalent, when the platform is known to be `s32k3`:

   ```matlab
   import mbd_s32k3.common.*
   nxp.utils.open_config_tool(hCS, hCS, component);
   ```

   `open_config_tool(hObj, hCS, componentType)` internally dispatches to:
   - `mbd_{platform}.common.nxp.utils.s32ct.open_tool(hObj, hCS, componentType)` for S32 Config Tool, or
   - `mbd_{platform}.common.nxp.utils.ebt.open_tool(hObj, hCS)` for EB tresos.

7. **Verify the launch** by checking that the expected process is running (best-effort -- the tool starts asynchronously and may need several seconds to fully load):

   - S32CT: `tools.exe` (or `tasklist | findstr tools.exe`).
   - EB tresos: `tresos*.exe`.

8. **Report** briefly: detected platform, tool launched, model name, artefact path (the `.mex` or `_TresosProject` folder), and the focused component if any.

## Reference flow

The end-to-end MATLAB block to use via `evaluate_matlab_code` (platform auto-detected):

```matlab
mdl       = '{MODEL_NAME}';
component = 'Mcu';     % or any of: Adc, Can, Dio, Pwm, Spi, Uart, Port, Mcl, ...

% Make this model the current system (the helper consults gcs)
load_system(mdl);
set_param(0, 'CurrentSystem', mdl);

hCS  = getActiveConfigSet(mdl);
tool = codertarget.data.getParameterValue(hCS, 'Configuration_tool');

% Detect the MBDT platform package by probing for its open_config_tool helper
candidates = {'s32k3'};
platform = '';
for k = 1:numel(candidates)
    if exist(['mbd_' candidates{k} '.common.nxp.utils.open_config_tool'], 'file') == 2
        platform = candidates{k}; break
    end
end
assert(~isempty(platform), 'No MBDT platform package found on the path.');

fprintf('Platform            : %s\n', platform);
fprintf('Configuration_tool  : %s\n', tool);
fprintf('Component focus     : %s\n', component);

% Drive the same callback as the "Open" / "Configure" button
feval(['mbd_' platform '.common.nxp.utils.open_config_tool'], hCS, hCS, component);

% Best-effort verification (Windows)
[~, tasks] = dos('tasklist');
switch tool
    case 'S32 Config Tool'
        if ~isempty(regexp(tasks, '\s+tools\.exe', 'match'))
            disp('S32 Configuration Tools is running.');
        end
    case 'EB tresos'
        if ~isempty(regexp(tasks, 'tresos.*\.exe', 'match'))
            disp('EB tresos is running.');
        end
end
```

> A ready-to-run version is in [`reference/open_config_tool.m`](./reference/open_config_tool.m).

## Examples

| User says | Tool launched | Focused component |
|---|---|---|
| "Open the external configuration tool." | based on `Configuration_tool` | `Mcu` (default) |
| "Open S32CT for `{model}`." | S32 Config Tool | `Mcu` |
| "Show the ADC configuration in S32 Config Tool." | S32 Config Tool | `Adc` |
| "Open the peripheral configuration on the PWM." | based on `Configuration_tool` | `Pwm` |
| "Launch EB tresos for this model." | EB tresos | n/a (EB tresos opens at project root) |

## Guardrails

- **Never operate on a microcontroller without first verifying the MBDT family toolbox is installed.** Before opening the config tool for a given platform, call the MCP tool `detect_matlab_toolboxes` (or, as a MATLAB-side fallback, run `ver` with no arguments and inspect the `Name` field) and require an entry matching `Model-Based Design Toolbox for S32{family}...` (e.g. `Model-Based Design Toolbox for S32K3 Series`). The `HardwareBoard` parameter or an `mbd_*` package being on the path is **not** proof of installation. If the toolbox is not installed, stop, report the missing toolbox by its product name (e.g. `Model-Based Design Toolbox for S32K3 Series`), and ask the user to install it -- never fabricate a tool location, never substitute a different family's helper.
- **Always go through `mbd_{platform}.common.nxp.utils.open_config_tool`** (or its inner `s32ct.open_tool` / `ebt.open_tool`). Never call `tools.exe` directly with hand-built command lines -- you'd skip project regeneration, the *"already open"* check, and the HTTP focus call.
- **Detect the platform at runtime.** Do not hard-code `s32k3`. Probe the available `mbd_*` packages and pick the one whose helper exists, or use the model's `HardwareBoard` to choose.
- **Always set `CurrentSystem` to the target model** before the call. The helper inspects `gcs` and silently no-ops on library blocks.
- **Never pass an empty `component`.** The S32CT helper has a quirk where empty / unknown components cause its `idx` resolution to fail before `tools.exe` is spawned. Default to **`Mcu`** when the user did not name a peripheral.
- **Do not change `Hardware.SelectDefaultLoc`, `Hardware_type`, `Configuration_tool`, or any other config-set field.** This skill is read-only on the model.
- **Respect the *already open* state.** If S32CT (`tools.exe`) is already running, the MBDT helper shows a message box and does not spawn another instance -- that is the correct behaviour. Do not attempt to kill and relaunch.
- **Do not save the model.** This skill should not modify the model on disk.
- **For non-MBDT targets, stop and report.** Do not try to open S32CT against a model whose `HardwareBoard` is not an NXP MBDT-managed board.
- **For peripheral focus to work in S32CT, the project must be loaded.** The helper waits up to 60 s on `http://localhost:11001/common/configuration` before issuing the focus URI. If the user reports the focus didn't happen, suggest re-running the skill with the same component once the tool finishes loading.

## Validation loop

1. After `feval(['mbd_' platform '.common.nxp.utils.open_config_tool'], ...)` returns without error, check that the expected process is running (best-effort -- the tool starts asynchronously).
2. For S32CT, verify `tools.exe` appears in the process list. For EB tresos, verify a `tresos*.exe` process.
3. If the process is not yet visible, wait a few seconds and recheck -- the tool may still be loading.
4. Report the detected platform, the tool launched, the model name, the artefact path (`.mex` or `_TresosProject`), and the focused component.

## References

- `setting-mbdt-target-mcu` (per platform) -- change the target MCU / custom board first; this skill opens whatever was selected.
