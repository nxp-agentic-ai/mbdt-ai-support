---
name: building-mbdt-model
description: "Use when the user asks to generate code, build, compile, rebuild, flash, download, program, deploy, or run on target for an NXP MBDT Simulink model on any supported platform (S32K3); also triggers on Ctrl+B, slbuild, 'build for monitoring', build errors, linker errors, compiler errors, stale build folders, ert_main, generated code issues, missing source files, or re-building after target/config/model-copy/toolchain changes. Do NOT use for: changing Configuration Parameters or Hardware Implementation pane settings (use setting-mbdt-model-params), changing the target MCU or processor (use setting-mbdt-target-mcu), opening or copying a shipped example (use opening-mbdt-example), configuring or tuning MBDT driver blocks (use configuring-mbdt-blocks), running PIL or SIL simulation (use PIL/SIL skill), launching FreeMASTER for live monitoring, opening S32CT or EB tresos (use opening-mbdt-config-tool), or opening/importing the S32DS project (use managing-mbdt-s32ds-project)."
license: LA_OPT_Online Code Hosting NXP_Software_License
metadata:
  author: NXP
  version: "1.0.0"
  product: nxp-mbdt
  tags: '[mbdt, build, deploy]'
---

# Building and Deploying an NXP MBDT Model

Generate code, build, and deploy an NXP MBDT Simulink model to the target board in one step -- the programmatic equivalent of pressing **Ctrl+B**. The skill dispatches a single call through `evaluate_matlab_code`; the MBDT toolchain attached to the model handles code generation, compilation, linking, and on-target flashing automatically.

## When to Use

- The user asks to generate code, build, compile, rebuild, flash, download, program, deploy, or run on target.
- The user asks to "do a Ctrl+B" or "build for monitoring".
- The user reports a failed build -- see [Recovering from Build Errors](#recovering-from-build-errors).

## When NOT to Use

- The user wants to change Configuration Parameters before building -> use `setting-mbdt-model-params` first.
- The user wants to change the target MCU before building -> use `setting-mbdt-target-mcu` first.
- The user wants to read or modify generated C code without rebuilding -> out of scope.
- The user wants to open the external configuration tool -> use `opening-mbdt-config-tool`.

## Workflow

1. **Identify the model.** If unspecified and exactly one MBDT model is open, use it. Otherwise ask.
2. **Verify the model targets an MBDT platform.** If it does not, stop and report.
3. **Invoke the Build action.** Call `evaluate_matlab_code` with `slbuild('{modelName}')`. The MBDT toolchain takes over from here: generates C code, runs its GCC, links the executable, and flashes the board.
4. **Report** briefly: model name, build outcome, and (when reported by the toolchain) whether deployment completed.

Failures surface as MATLAB errors from `slbuild`. Report the identifier and message; do not retry blindly.

## Recovering from Build Errors

Apply the levels below **in order** and re-run `slbuild('{modelName}')` after each. Escalate only if the build still fails.

### Level 1 -- Stale generated folders (always try first)

Symptoms: file-not-found, incremental-rebuild mismatches, out-of-date dependency errors, "file already exists / cannot overwrite" in code-generation.

Delete the model's generated folders in its working directory:
- `{modelName}_ert_rtw/`
- `{modelName}_Config/`

MBDT regenerates both on the next build.

### Level 2 -- Stale model settings (target / config / `.mex` changed)

Apply in addition to Level 1 when **any** of the following happened since the last successful build:

- The target MCU / processor / hardware part was changed.
- The configuration tool was switched (e.g. S32 Config Tool <-> EB tresos).
- The model was copied, renamed, or moved.
- The model's `.mex` was replaced, re-imported, or regenerated from S32CT.
- Configuration Parameters / Hardware Implementation were edited without the in-memory MBDT settings being refreshed.

MBDT caches each model's settings in **two** places -- both must be cleared:

1. **Delete the on-disk MBDT settings file** next to the model (or next to the data dictionary, for `.sldd`-stored ConfigSets): `{modelDir}/{ConfigName}_settings.mat` -- typically `{modelDir}/{modelName}_settings.mat`.
2. **Delete the in-memory entry** by force-unlocking and clearing the settings class -- `munlock mbd_{family}.common.nxp.settings; clear mbd_{family}.common.nxp.settings;`. The map is locked with `mlock` and is **not** cleared by `clear all` / `clear classes`. This discards every model's in-memory MBDT settings for that family; there is no supported single-model eviction (the underlying `get_map` is `private`).

Deleting only the MAT-file is not enough -- the in-memory map will write the stale state back on the next save.

### Level 3 -- Stop and report

If Levels 1 and 2 both failed, surface the original `slbuild` error to the user. Do not repair files inside `{modelName}_ert_rtw/`, `{modelName}_Config/`, or hand-edit `{modelName}_settings.mat`.

## Examples

| User says | What the agent does |
|---|---|
| "Generate code." / "Build the model." / "Do a Ctrl+B." | Calls `slbuild('{modelName}')`. |
| "Flash the board." / "Deploy on hardware." / "Compile and run on the board." | Same -- the MBDT toolchain performs the flash step as part of the Build action. |
| "The build is failing." (no other context) | Applies Level 1; re-runs `slbuild('{modelName}')`. |
| "I changed the target MCU / copied the model / replaced the `.mex` and the build fails." | Applies Level 1 **and** Level 2; re-runs `slbuild('{modelName}')`. |

## Guardrails

- **Never compose a makefile, invoke `make`, call the in-toolbox GCC directly, or build the generated C by hand.** The MBDT toolchain owns the entire code-gen + compile + link + flash chain. Use `slbuild('{modelName}')` -- nothing else.
- **Never call internal MBDT build helpers directly** (`nxp.build.*`, `mbd_*.build.*`, `codertarget.*` internals). They assume invocation from within Simulink's Build action.
- **Never recreate or hand-edit `{modelName}_ert_rtw/` or `{modelName}_Config/`.** Either delete both folders in full and let MBDT regenerate them, or leave them untouched.
- **Never recreate or hand-edit `{modelName}_settings.mat`.** When recovering from a target / config / `.mex` change or a model copy/move, delete the on-disk file **and** wipe the in-memory cache (`munlock` + `clear` of `mbd_{family}.common.nxp.settings`); deleting only the MAT-file leaves the stale `mlock`'d map to overwrite it on the next save.
- **Never operate on a microcontroller without first verifying the MBDT family toolbox is installed** (via `detect_matlab_toolboxes` or `ver`). Require a `Model-Based Design Toolbox for S32{family}...` entry matching the model's target.
- **Never fabricate runtime values.** Model name, family, build-tool paths, and flasher options live on the model -- ask if ambiguous.
- **`slbuild` is the single entry point.** `rtwbuild` is accepted only when `slbuild` is unavailable in the active release.
- **Stop and ask** if the user requests an offline build, a partial step (code-gen only), or a toolchain swap -- those are configured via `setting-mbdt-model-params`, not by altering the Build call.

## Validation loop

1. Check that `slbuild` returned without error; the Command Window should print `### Successful completion of build procedure for model: {modelName}`.
2. If the build fails, apply the recovery levels in order and re-run; do not declare success until the `slbuild` call exits cleanly.
3. Report the final build outcome, including flash/deployment status when the toolchain reports it.

## References

- `setting-mbdt-model-params` -- change Configuration Parameters before building.
- `setting-mbdt-target-mcu` -- change the target MCU before building.
- `opening-mbdt-example` -- open a shipped example already configured for Build.

---
