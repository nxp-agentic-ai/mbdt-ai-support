---
name: configuring-mbdt-blocks
description: "Use when the user wants to add, read, configure, set a parameter on, select a driver function (api_func) for, or wire an interrupt for any NXP MBDT driver block on a Simulink model, or asks why block parameters are grayed out or hidden. Covers one block per Real-Time Driver component (Can, Adc, Dio, Pwm, Spi, Uart, I2c, Lin, Gpt, Icu, Mcl, Mem, Fee, MotorControl, FreeMASTER, Profiler, ISR handler) on any MBDT platform (S32K3), via live get_param/set_param discovery. Out of scope: Hardware Implementation fields, target MCU selection, opening S32CT or EB tresos."
license: LA_OPT_Online Code Hosting NXP_Software_License
metadata:
  author: NXP
  version: "1.0.0"
  product: nxp-mbdt
  tags: '[mbdt, blocks, configuration]'
---


# Configuring NXP MBDT Blocks

Use this skill to read or set parameters on NXP MBDT driver blocks (one block per Real-Time Driver component, e.g. `Can`, `Adc`, `Dio`, `Pwm`, `Mcl`, `MotorControl`, `Hardware_Interrupt_Handler`, ...) on a Simulink model targeting any NXP MBDT platform.

The governing principle is **live discovery, never memory**: block existence comes from `get_mbdt_toolbox(family, 'blocks')`, and every parameter name, type, enum entry, and current value comes from `get_param(blockPath, 'DialogParameters')`. Edits are applied with `set_param(blockPath, paramName, value)`. All three run through the `evaluate_matlab_code` MCP tool. Structural edits (adding a block that is not yet on the canvas) use `model_edit` -- see `building-simulink-models`.

## When to Use

- **Add** an MBDT block (`"add a Can block"`, `"insert a Dio block"`).
- **Set / change / pick** a function or parameter (`"set api_func on Can to Can_Write"`, `"change the channel on Dio"`).
- **Route an interrupt / callback** for any peripheral (`"handle the Adc ISR"`, `"wire the Can RX interrupt"`).
- Explain why a parameter is **hidden / disabled / grayed out**, or why ports changed when a function was picked.
- Ask what **functions** a block can implement.

## When NOT to Use

- **Configuration Parameters -> Hardware Implementation** fields (PIL, Clocking, Build, peripheral-wide options) -> `setting-mbdt-model-params`.
- **Target MCU / processor / configuration template** -> `setting-mbdt-target-mcu`.
- **Opening the external config tool** (S32CT or EB tresos) -> `opening-mbdt-config-tool`.
- **Populating dropdown entries** (channels, instances, controllers) -- owned by the external config tool; open it via `opening-mbdt-config-tool`, never synthesize entries here.
- **Build error about a missing C function** -- do not stub it (see Guardrails).
- **Build error about a missing generated *config file*** (`*_Cfg.h`, `*_CfgDefines.h`, `*_PBcfg.*`) -- this is NOT a model-side or block problem; the external config tool did not emit that unit. Go read the actual config-tool errors (see "Expected generated files and the missing-file diagnostic").

## RTD component documentation (Integration + User Manual)

Every RTD driver component ships two authoritative PDFs on disk -- consult them before citing driver API, generated files, or init prerequisites from memory:

- **User Manual (UM)** -- every `{Driver}_*` C-function's signature, semantics, and return codes. Each of those functions is exactly one entry in the block's `api_func` dropdown (read via `get_param({blk},'DialogParameters')`); read the UM before selecting or explaining an `api_func`.
- **Integration Manual (IM)** -- expected generated files, init order, `{Driver}_Init` prerequisites, memory sections, NVIC setup. Read before editing `.mex` structure, board init, or diagnosing a missing generated config unit.

**On-disk pattern (family-generic, always glob the version segments):**

```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\{Module}_TS_T40D*_M70I*_R0\doc\
    RTD_{MODULE}_IM.pdf   RTD_{MODULE}_UM.pdf
```

`{family_root}` = `mbd_find_{family}_root()` (MATLAB). `{Module}` = S32CT `type_id` from `nxp_s32ct_inspect(kind='instances')` (`Adc`, `Pwm`, `Spi`, ... or AUTOSAR-suffixed like `Can_43_FLEXCAN`, `Lin_43_LPUART_FLEXIO`, `Eth_43_GMAC`); `{MODULE}` is that name uppercased.

## Expected generated files and the missing-file diagnostic


A correctly-configured peripheral does not just place a block and route an ISR -- it must cause the external config tool (S32CT or EB tresos) to **emit a set of generated C artifacts**. If those artifacts are absent, the model looks fine, `SimulationCommand update` passes, and the failure only surfaces late at compile/link time as a missing header or unresolved symbol.

**Two distinct failure classes -- do not confuse them:**

1. **Missing C *function*** (unresolved `{Driver}_Init` / `{Driver}_SyncTransmit` at link) -> the driver is declared but not *called*: the board-init entry is missing, or `api_func` points at a function the tool did not generate. Fix per the peripheral reference (board-init) or change `api_func`. **Never stub it** (existing guardrail).

2. **Missing generated *config unit*** (`fatal error: {IP}_Ip_CfgDefines.h` / `{Driver}_Cfg.h` No such file) -> the config tool **did not generate that unit at all**. This is authoritative evidence of a config-tool-side problem, NOT a Simulink problem. **Do not diagnose model-side.** Instead:
   - **Read the config tool's own errors.** For S32CT: `nxp_s32ct_validate(project_path={.mex}, tool_name={Tool})` and read the parsed problem records. The launcher's exit code is untrustworthy (it exits 0 even with errors) -- read the problem text, not the return code. For EB tresos: run its code-gen and read the emitted log, or open the tool via `opening-mbdt-config-tool`.
   - **Suspect leftover / mixed peripheral "flavors."** A stale example channel or a `*Used=true` flag from a shipped example (e.g. a FLEXIO channel plus `I2cFlexIOUsed=true` left alongside your intended LPI2C channel) can silently **suppress emission of the intended driver's config unit** while still validating superficially. Remove the unused/leftover flavor in the config tool, then re-validate and re-generate.
   - **Imported / cloned / example-derived projects carry leftovers.** Any project that started life as a shipped example, a template, or a copy from another board drags along channels, flags, pin routings, and enabled flavors that the current application does not use. These residues are the most common cause of a config unit failing to emit. Treat every inherited `.mex` / tresos project as suspect.
   - **When you do not know where to look, diff against a known-good default.** If the validation output does not point at an obvious culprit, generate a *fresh default* project for the same MCU / package / driver (or open the corresponding shipped default) and compare it against yours -- the extra or differently-flavored entries in your project are the leftovers to remove. Aligning your project to the default configuration is the fastest way to locate what is suppressing code-gen.
   - **The `.mex` is a first-class edit surface.** Fixing code-gen sometimes requires editing the `.mex` config directly (baudrate/mode validation, removing stale channels), not the model. Cross-reference the `s32ct-peripherals-*` and `s32ct-*-graft-mex` skills for structured `.mex` edits.

**Rule:** when a build fails on a *missing generated file*, your first action is to run the config tool's validation and read its actual errors -- before touching the model or any block parameter.


## The Block Behavioral Model

The single mental model to apply to any MBDT block. Live discovery is what makes each claim safe; none of these overrides the `DialogParameters` of the block in front of you.

1. **One block per Real-Time Driver component.** Each is an `S-Function` with `MaskType` of shape `{family}_{role}` (e.g. `s32k3_can`, `s32m2_dpga`, `s32ze_pwm`). Its generated code inserts the corresponding RTD C-function call.

2. **`api_func` is the master control.** When present it is the function selector: it reshapes the S-Function's ports, shows/hides/enables every other parameter via the mask callback, and maps 1:1 to the RTD C-function name. Hidden/disabled parameters carry no meaning for the current function. **Always set `api_func` first**, then read the parameters the block now shows.

3. **Dropdown entries are owned by the external config tool.** All resource enums (`channel`, `controller`, `instance`, `hw_unit`, `port`, `group`, `hw_obj`, `blockName`, `reg`, `irqGroup`, `irqHandlers`, `cantxobj`, `canrxobj`, ...) are populated from the S32CT `.mex` project or the EB tresos `_TresosProject` folder. When unconfigured, the enum holds exactly one **sentinel** of shape `"No {thing} configured"` / `"No {thing} available"`. The sentinel is **not** a valid selection -- it means the resource is not declared. Open the config tool via `opening-mbdt-config-tool`; never invent entries and never "pick" or strip the sentinel.

4. **ISRs and callbacks have one owner per family.** Never a per-peripheral parameter. They route exclusively through the family's single ISR-handler block: `Hardware_Interrupt_Handler` (S32K3) or `ISR Handler` (S32N), all `MaskType = {family}_isr_handler`. `irqGroup` names the owning driver (`Adc`, `Can`, `Pwm`, ...); `irqHandlers` cascades from it to the specific handler.

5. **Closed parameter type set.** Every dialog parameter has `Type in {enum, boolean, string}`:
   - `enum` -> one exact entry from `dp.{name}.Enum` (validate before set, case-sensitive).
   - `boolean` -> the string `'on'` or `'off'`.
   - `string` -> free-form; preserve user formatting (e.g. `0x` prefixes).
   No matrices, popup tables, or listboxes appear. Any other `Type` is a discovery anomaly: stop and report it.

6. **System-managed parameters are read-only.** `text` (most peripheral blocks), `descript` (`Read_Register` / `Write_Register`), and `blockCbk` (ISR-handler block) are written by the mask Initialization code -- a cached dump of the config tree (`text`, `descript`) or a serialized callback registry (`blockCbk`). Setting them is silently overwritten on refresh or produces incoherent state that only surfaces at code generation. Read with `get_param`; never `set_param`.

7. **Config Parameters vs block parameters are different worlds.** Driver-wide settings (Build, Clocking, PIL, target MCU, per-driver Hardware Implementation) live in Configuration Parameters (`setting-mbdt-model-params`). Block dialog parameters live in `DialogParameters` (this skill). Do not conflate.

8. **Block availability is a runtime query.** Some blocks exist only on some families (`MotorControl`, `Rdc_Checker`, `eTPU`, `TPP Config` on S32K3; `Ae`, `Dpga`, `Gdu` on S32M2; ISR-handler named `ISR Handler` on S32N, `Hardware_Interrupt_Handler` elsewhere). Always resolve via `get_mbdt_toolbox(family, 'blocks')`; never assert existence from training data.

## Workflow

1. **Identify the target.** Determine model, MBDT family, and block. Detect family from the model's hardware target if ambiguous; ask if the block name is ambiguous. If a named block does not exist, list what does (Step 5).

2. **Verify the family toolbox is installed.** Call `detect_matlab_toolboxes`; require a `Model-Based Design Toolbox for S32{family}...` entry. A `HardwareBoard` value or an `mbd_*` package on the path is not proof. If missing, stop, name the product, ask -- never substitute another family's library (`get_mbdt_toolbox` silently lists whatever family is installed).

3. **Preflight -- hardware target resolved.** Before *adding* any block, read `get_param({model},'HardwareBoard')` (and the family `SystemTargetFile`) and confirm it matches Step 2 and the intended MCU / board. If unset, mismatched, or generic (`MATLAB Host`, plain ERT), stop and route to `setting-mbdt-target-mcu`. A block on an untargeted model resolves against whichever family is first on the path and generates silently-wrong code later.

4. **Preflight -- driver component declared.** Before adding a peripheral block or selecting a resource enum, confirm the driver component exists in the external config tool. For S32CT, call `nxp_s32ct_inspect(kind='instances')` and check the driver's `type_id` is present. For EB tresos, read `{model}_TresosProject/config.project` (or ask the user to confirm via `opening-mbdt-config-tool`). If missing, stop and route to `opening-mbdt-config-tool` -- a missing component means the board-init entry is also missing and the peripheral will build but carry no traffic (silent failure). See the Preflight quick reference and the peripheral reference for the exact `type_id`.

5. **Discover the live block catalog** via `get_mbdt_toolbox(family, 'blocks')` (each line `"{block} - {internal parent path}"`). This is the single source of truth for block existence. Resolve the user's wording against it; refuse near-misses.

6. **Read the live parameter set** via `get_param({blockPath}, 'DialogParameters')` -- the single source of truth for what may be set (each entry has `Type`, `Prompt`, `Attributes`, and for `enum` its `Enum`). Never carry names, enums, prompts, or values from memory. If a resource enum returns only a sentinel, return to Step 4 (declaration missing).

7. **Apply the behavioral model.** Interpret per the section above: closed type set, read-only system fields (`text`, `descript`, `blockCbk`), sentinel semantics, ISR routing to the family handler.

8. **For ISR / callback requests, use the family ISR-handler block** (behavioral model #4). Resolve its name via `get_mbdt_toolbox`; add one via `model_edit` if absent; set `irqGroup` (owning driver) then `irqHandlers` (specific handler). Never add an ISR parameter to the peripheral block.

9. **Apply the change** via `set_param` (see Applying the Change). Multiple parameters on one block go in order: **`api_func` first, then resource enums, then boolean flags** (see Set order). One `set_param` per parameter.

10. **Report** briefly: model, block, each parameter changed (Name + Prompt from Step 6), previous -> new value. Assert only what came from Steps 3-6.

### Preflight quick reference (illustrative only)

Steps 3-4 apply to every peripheral. The authoritative list per `.mex` comes from `nxp_s32ct_inspect(kind='instances')`; the driver `type_id` matches the header emitted into `mbdt_board_init.c` and the board-init component name. Suffixes drift between toolbox versions -- never rely on this table alone. For CAN, UART, LIN, and I2C the authoritative `type_id` and board-init symbol are in the per-peripheral reference (see the References section below); the References table supersedes this one for those four. If you cannot resolve the mapping, ask -- never invent a `type_id`.

| Peripheral | Example `type_id` | Reference |
|---|---|---|
| ADC / DIO / GPT / ICU / MCL / PWM / SPI | `Adc` / `Dio` / `Gpt` / `Icu` / `Mcl` / `Pwm` / `Spi` | *(live discovery)* |
| FEE / Internal flash / Mem access | `Fee` / `Mem_43_INFLS` / `MemAcc` | *(live discovery)* |
| Mcu / Platform / Port | `Mcu` / `Platform` / `Port` | *(live discovery)* |

## Set order and value normalization

- **Set order on a single block:** (1) `api_func`, (2) resource enums (`channel`, `controller`, `instance`, `hw_unit`, `port`, `group`, `connection_type`, `memoryType`, ...), (3) boolean flags (`canfd_msg`, `ext_id_msg`, `gpioSim`, ...). Order matters because each `set_param` fires the mask callback that reshapes ports and toggles `Visible`/`Enabled`; setting a resource enum before `api_func` leaves it on a stale hidden slot and the model is incoherent.
- **Boolean aliases:** enable / check / on / true / yes / 1 -> `'on'`; disable / uncheck / off / false / no / 0 -> `'off'`.
- **Enum values:** validate against `dp.{name}.Enum`; pass through unchanged (case-sensitive). Never lowercase, trim, strip prefixes, or accept a near-miss. If not in the live list, present the list and ask. C-function names (`Can_Write`, `Adc_StartGroupConversion`) and resource IDs (`PORT_A_PIN_5`, `CAN_CTRL_0`) are exact toolbox-owned strings.
- **Empty `Prompt`:** fall back to the parameter `Name` as label (typically `text` / `descript`, both system-managed).

## Applying the Change

Use the native Simulink API through `evaluate_matlab_code`. No MBDT-specific tool exists or is needed -- `get_param(blockPath,'DialogParameters')` already carries everything (names, `Type`, `Prompt`, `Enum`, `Attributes`).

- Read the parameter set: `get_param({blockPath}, 'DialogParameters')`.
- Read a value: `get_param({blockPath}, {paramName})`.
- Set a value: `set_param({blockPath}, {paramName}, {value})` -- one call per parameter, in the Set order above. `{value}` is an exact `dp.{name}.Enum` entry for `enum`, `'on'`/`'off'` for `boolean`, a free-form char vector for `string`.
- Add a block not yet on the model (structural): `model_edit` `add_block` with `type` taken from a `get_mbdt_toolbox(family, 'blocks')` line; then return to the get/set flow. This is the only documented fallback route.

This skill does **not** save the model. To persist, call `save_system({model})` via `evaluate_matlab_code` separately, and say so when reporting.

## Examples

| User says | What the agent does |
|---|---|
| "Add a Can block to `{model}` and send a frame." | Preflight target (Step 3) + `Can_43_FLEXCAN` present via `nxp_s32ct_inspect` (Step 4); route out on failure. If no `Can` block yet, optionally open a shipped example via `opening-mbdt-example` and mirror its config-tool + block topology (Can block plus the family ISR-handler for RX/TX notifications). Resolve `Can` via `get_mbdt_toolbox`, insert via `model_edit`, then `set_param(blk,'api_func','Can_Write')` first, then `controller` / `hw_obj` from live enums. |
| "Add a Uart block to `{model}`." | Same preflight pair (target + `Uart` in instances). Route out on failure. Then discover via `get_mbdt_toolbox` and insert via `model_edit`. |
| "Set the channel on the Dio block to 3." | Read `DialogParameters`; read `dp.channel.Enum`. If only `"No {thing} configured"`, **first `open_system({blk})` + `pause(1)`** to fire the mask callback that repopulates the dropdown, then re-read the enum (linked MBDT blocks often serve a *stale* cached sentinel until opened). Only if the entry is still missing, route to `opening-mbdt-config-tool`. Else `set_param({dioBlk},'channel',{exact entry})`. |
| "Why are most fields on the Adc block grayed out?" | Explain `api_func` is the master control; read `dp.api_func.Enum` and current value live; describe what each value exposes without inventing anything. |
| "Handle the Adc ISR." | Resolve the ISR-handler block name via `get_mbdt_toolbox`; add via `model_edit` if absent; `set_param({isrBlk},'irqGroup','Adc')`, then `irqHandlers` from the live cascade. Never add an ISR parameter to the Adc block. |
| "Set `text` on the Can block." | Refuse: system-managed. Read and report the current value instead. |
| "Add a stub for `Can_Write` so the build links." | Refuse (Guardrail). Change `api_func` to a generated function, or define the handler via `opening-mbdt-config-tool`. |
| "Change the target MCU." | Out of scope -> `setting-mbdt-target-mcu`. |
| "Set the PIL COM port to COM5." | Out of scope -> `setting-mbdt-model-params`. |

## Guardrails

- **Never fabricate runtime values.** Block names, parameter names, prompts, enum entries (function / channel / controller / instance / interrupt-group / handler / register names), and current values come only from `get_mbdt_toolbox` (existence) and `get_param(...,'DialogParameters')` (parameters). If discovery fails or returns an empty/sentinel list, stop and ask.
- **Never act on a platform without verifying the MBDT toolbox is installed.** Before adding, reading, or configuring any block, call `detect_matlab_toolboxes` and require a `Model-Based Design Toolbox for S32{family}...` entry (Workflow Step 2). A `HardwareBoard` value or an `mbd_*` package on the path is not proof. If the family toolbox is absent, stop, name the missing product, and ask -- never substitute another family's library.
- **Never proceed on an unverified toolbox / target / declaration.** The three preflights (Steps 2, 3, 4) are mandatory before adding a block or selecting a resource enum. On any failure -- wrong family library, untargeted model, sentinel enums (`"No {thing} configured"` / `"No {thing} available"`), missing board-init entry -- route out to the named skill (`setting-mbdt-target-mcu` / `opening-mbdt-config-tool`) rather than pressing ahead. All four failures are silent and surface only at code generation. A sentinel is never a valid selection; activating a previously-unused peripheral additionally requires clocks gated on, pins muxed, controller enabled, and interrupts declared in the config tool.
- **Never route an interrupt through a peripheral-block parameter.** All ISR/callback wiring lives on the family ISR-handler block (`Hardware_Interrupt_Handler` / `ISR Handler`, `MaskType = {family}_isr_handler`). Do not add or invent an `isr_*` / `callback_*` / `notification_*` parameter on the peripheral block, even if a similarly named field exists in non-MBDT blocks.
- **Never set system-managed parameters** (`text`, `descript`, `blockCbk`). Read with `get_param`; never `set_param`.
- **Never stub a missing RTD function to make the build link.** Do not insert a manual stub in the generated C, model, or S-Function. Change `api_func` to a function the config tool has generated, or define the handler via `opening-mbdt-config-tool`. Refuse stub-creation outright.
- **Closed type set is a contract.** Any parameter whose `Type` is not `enum`/`boolean`/`string` is a discovery anomaly: stop and report it; do not invent a set-value shape.
- **Never include implementation code in this SKILL.md.** The single-line `get_param` / `set_param` reference forms are the only allowed inline code; multi-statement scripts belong in a tool.
- **The change lives in memory only.** `set_param` does not save; call `save_system` separately if persistence is wanted, and say so explicitly when reporting.
- **Never disable or break the library link on an MBDT block.** MBDT driver blocks are resolved links into the family library; their configuration (including `api_func`) only persists across save/reload while the link stays `resolved`. Never set `LinkStatus` to `inactive` / `none`, never "disable" or "break" a link, and never save a model that reports disabled library links. If a link is accidentally left `inactive` (Simulink warns "contains disabled library links"), recover it before saving: `open_system({blk})`, `pause`, then `set_param({blk},'LinkStatus','restore')`, and confirm it returns to `resolved`. A block saved with a disabled link silently discards its mask-parameter overrides (e.g. `api_func`) on the next load -- which manifests as a value that "keeps reverting."
- **Judge and report a block by its function (`api_func`), not its name.** Never assume what an MBDT block does from its displayed name -- the name is cosmetic, user-editable, and carries no semantics. A block's actual behavior is defined solely by its `api_func` value (which maps 1:1 to the RTD C-function it emits). Whatever a block is called, always read `api_func` with `get_param` before asserting or reporting what it does, and change `api_func` (never the name) to change behavior. This rule applies to every block on every family -- do not special-case it to any particular peripheral or naming convention.

## Validation loop

1. After each `set_param`, verify with `get_param({blockPath}, {paramName})` and compare to the intended value.
2. If ports or visibility changed unexpectedly, re-read `DialogParameters` and compare against the expected post-`api_func` state.
3. Report only values confirmed by live `get_param`.

## References

Per-peripheral references are self-contained deep dives (behavioral model, ISR wiring, init sequence, config-tool correlation, usage patterns, troubleshooting, board notes, peripheral guardrails). **Load the matching reference before configuring that peripheral** -- never rely on training data or generalization from a different peripheral. When possible, load it before Workflow Step 4: its Sec.6 gives the authoritative `type_id` and board-init component name, superseding the illustrative Preflight table.

| Peripheral | Reference | When to load it |
|---|---|---|
| ADC | [`reference/adc.md`](reference/adc.md) | Add/configure an `Adc` block or wire an ADC conversion-complete notification. ADC is group-based (HW-unit -> group -> channel), needs a mandatory `Adc_SetupResultBuffer` in the Initialize Function, and is frequently a hardware-trigger *sink* (BCTU/CTU cross-triggered from a PWM/eMIOS edge via TRGMUX -> LCU). |
| CAN (classic + CAN FD) | [`reference/can.md`](reference/can.md) | Add/configure/route a `Can` block or wire `CanIf_*` callbacks (RxIndication, TxConfirmation, ControllerBusOff, ...); also CAN transceiver init (five board patterns: GPIO wake-up, TJA1153 C-helper, jumper-selected, external discrete, I2C GPIO-expander). |
| DIO | [`reference/dio.md`](reference/dio.md) | Add/configure a `Dio` block (`Dio_WriteChannel` / `Dio_ReadChannel` / `Dio_FlipChannel` / port / channel-group). DIO is flat channel-based with application-named channels, has **no `Dio_Init`** (the pad is set up by `Port_Init` from the Port component) and **no interrupt of its own** (pin edge/level detection is the ICU driver's job); covers the Pins/PORT/DIO three-way relation and the per-family `DioChannelId` arithmetic (S32K3 half-port `32*port+pin` vs S32N virtual-GPIO controller-relative index). |
| GPT | [`reference/gpt.md`](reference/gpt.md) | Add/configure a `Gpt` block or wire a timer-expiry notification. GPT is channel-based and rides on a lower timer IP (PIT/STM); every MBDT GPT model carries two mandatory toolbox channels (`StepTimer`, `ProfilerTimer`) that must not be removed; the mandatory init action is `Gpt_StartTimer`, and the notification callback is IP-derived (`Gpt_PitNotification`). |
| I2C | [`reference/i2c.md`](reference/i2c.md) | Add/configure an `I2c` block or wire `MBDT_I2c_Callback`; includes the hardware pull-up requirement on S32K311EVB-Q100 / S32K312EVB-Q172 / S32K388EVB-Q289 (a common silent failure MBDT cannot fix model-side). |
| ICU | [`reference/icu.md`](reference/icu.md) | Add/configure an `Icu` block (edge counter / signal-edge detect / signal-measurement / timestamp) or wire an ICU notification. ICU owns pin edge/level detection (which DIO does not); channel-based, ties into the family ISR handler for edge/timestamp notifications. |
| LIN | [`reference/lin.md`](reference/lin.md) | Add/configure a `Lin` block or a `LinIf` callback block. LIN is architecturally different -- dedicated `LinIf` block (`MaskType = {family}_linif`) instead of `Hardware_Interrupt_Handler`, and `LinIf_HeaderIndication` is bidirectional (outputs trigger + Channel + Pid, takes back Cs / Drc / Dl / Data / Status). |
| FreeMASTER | [`reference/freemaster.md`](reference/freemaster.md) | Add/configure the `FreeMASTER Config` / `FreeMASTER Recorder` / `FreeMASTER Poll` blocks. FreeMASTER has no config-tool component (INV-1); rides on LPUART or FlexCAN (INV-2); three service modes (Poll-driven / Short Interrupt / Long Interrupt); MBDT auto-inserts a periodic poll. Also covers the `ExportedGlobal` / `Volatile` storage-class requirement for any variable observed from the host. |
| Profiler | [`reference/profiler.md`](reference/profiler.md) | Add/configure the `Profiler` block (start / stop pair on shared `index`, `showOut` decides ports). No config-tool component; the timer source is a model setting (`Timers_ProfilerTimer` -- family-dependent `SysTick` / `GPT` / `DWT`); MBDT auto-arms the referenced GPT channel. Measures the execution time of an atomic / function-call subsystem. |
| PWM | [`reference/pwm.md`](reference/pwm.md) | Add/configure a `Pwm` block or wire a per-channel edge notification. PWM is channel-based (`PwmChannel_N` routed to eMIOS instances), needs no mandatory Initialize Function block, and is frequently a hardware-trigger *source* for the ADC (PWM/eMIOS edge -> TRGMUX -> LCU -> BCTU, routed via the `Mcl` driver). |
| SPI | [`reference/spi.md`](reference/spi.md) | Add/configure an `Spi` block or wire `MBDT_SPI_end_job*_callback` / `MBDT_SPI_end_sequence*_callback`; covers the External Device -> Sequence -> Job -> Channel hierarchy, IB/EB channel buffers, chip-select config, and the dual per-Job/per-Sequence notification pattern. |
| UART | [`reference/uart.md`](reference/uart.md) | Add/configure a `Uart` block or wire `MBDT_Uart_Callback` in any of four modes (sync / async / buffer via `Uart_SetBuffer` / DMA-backed); covers the LPUART-vs-FreeMASTER exclusivity rule. |

**Precedence:** a reference beats training data or an adjacent reference; for two conflicting references, the one for the peripheral in front of you wins.

**Missing reference?** For a peripheral without a reference file (MCL, Fee, Mem, MotorControl, ...), follow the Workflow without one, and lean on the shipped MBDT examples as the substitute curated source:

1. **Open the matching example** for that peripheral via `opening-mbdt-example` (its list comes from `get_mbdt_toolbox(family, 'examples')` -- pick the one whose name matches the peripheral / use case).
2. **Learn block usage from the example, not from memory:** read which MBDT blocks it places, how their `api_func` and resource enums are set (via `get_param(...,'DialogParameters')` on the example's blocks), how interrupts are routed to the family ISR-handler, and how the config tool declares the driver. Mirror that block set and topology into the user's model.
3. **Still disclose the gap:** tell the user you are working without a curated reference and that every peripheral-specific claim is derived from the shipped example plus live discovery (`get_mbdt_toolbox`, `get_param(...,'DialogParameters')`, `nxp_s32ct_inspect`) only -- never from training data.

**Authoring a new reference?** Copy [`reference/_template.md`](reference/_template.md) -- the skeleton for a per-peripheral reference (behavioral model, ISR wiring, init sequence, config-tool correlation, guardrails). Read it when adding a reference for a peripheral that does not yet have one; do not copy an existing peripheral's file.
