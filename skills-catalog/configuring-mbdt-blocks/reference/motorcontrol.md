# MotorControl -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the MotorControl
peripheral on NXP MBDT-targeted Simulink models. This document describes
the behavior of the `MotorControl` block
(`MaskType = s32k3_motorcontrol`), the initialization pattern, and the
external-config-tool dependencies. Verified on S32K3 only -- this block
lives in `mbd_s32k3_cdd_library` and is S32K3-specific.

> **Tip -- start from a shipped example.** Open a shipped MotorControl
> example via [`opening-mbdt-example`](../../opening-mbdt-example/SKILL.md);
> its `.mex` project plus its model forms a coherent end-to-end reference
> that mirrors the sections below. Never carry example names from
> memory -- discover them at runtime via `get_mbdt_toolbox('s32k3','examples')`.

---

## 0. Hardware Compatibility Warning

> **STOP -- verify hardware before adding any MotorControl block.**
>
> The MotorControl CDD requires dedicated motor-control hardware (eMIOS
> channels for PWM, ADC for current sensing, and encoder/resolver input).
> Not all S32K3 devices support this -- only the high-pin-count, motor-
> control-capable variants listed below. If the model targets a device not
> in this list, the `MotorControl_*` functions will not link and the block
> will produce a build error.
>
> **Supported devices (S32K3 motor-control variants, as of MBDT 1.8.0):**
> This list may be incomplete in future MBDT releases. When in doubt, verify
> live: `get_mbdt_toolbox('s32k3','devices')` and check the RTD MotorControl
> package for the installed version.
>
> | Device | Package | Notes |
> |---|---|---|
> | S32K341-Q172 | LQFP100 | Entry motor-control |
> | S32K342-Q172 | LQFP100 | |
> | S32K344-Q172 | LQFP100 | Most common for motor-control demos |
> | S32K344-Q257 | BGA257 | |
> | S32K348-Q172 | LQFP172 | |
> | S32K356-Q172 | LQFP172 | |
> | S32K358-Q172 | LQFP172 | Dual-motor capable |
> | S32K358-Q289 | BGA289 | |
> | S32K364-Q289 | BGA289 | |
> | S32K366-Q289 | BGA289 | |
> | S32K374-Q289 | BGA289 | |
> | S32K376-Q289 | BGA289 | |
> | S32K388-Q289 | BGA289 | |
> | S32K389-Q437 | MAPBGA437 | High-end, dual-motor |
> | S32K394-Q289 | BGA289 | |
> | S32K396-Q289 | BGA289 | |
>
> **Devices that do NOT support MotorControl** (no eMIOS motor-control
> channels): S32K310, S32K311, S32K312, S32K314, S32K322, S32K324, S32K328,
> S32K338.
>
> **Action:** If the model's `Hardware_type` is not in the supported list
> above, warn the user and ask them to switch to a motor-control-capable
> device via `set_mbdt_device` or `setting-mbdt-target-mcu` skill before
> adding any MotorControl blocks.
>
> Verify at runtime:
> ```matlab
> hCS = getActiveConfigSet(modelName);
> ctd = get_param(hCS, 'CoderTargetData');
> disp(ctd.Hardware_type)  % must be one of the supported devices above
> ```

---

## 1. Peripheral Overview

The MotorControl peripheral in MBDT wraps the NXP MotorControl CDD
(Complex Device Driver), which provides a unified API for motor control
algorithms running on S32K3 devices with dedicated motor-control hardware
(e.g. eMIOS-based PWM, ADC, encoder).

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT project: Peripherals -> MotorControl instance declaration | External to the model | External config tool |
| 2 | Board-init entry `MotorControl_Init(...)` | `mbdt_board_init.c` | `editing-mbdt-board-init` skill |
| 3 | Initialize Function blocks (enable, alignment, calibration priming) | Simulink model | This skill |
| 4 | Runtime blocks for control loop | Simulink model | This skill |

**Silent failure modes if any is missing:**

- Missing (1) -> `instance` enum resolves to `"No Instances configured"` sentinel.
- Missing (2) -> build links but every `MotorControl_*` call is a no-op.
- Missing (3) -> motor never enabled; alignment/calibration never executed.
- Missing (4) -> no control data transferred.

**Key departure from other peripherals:** The MotorControl block exposes
additional output-shaping enums (`paramInterpret`, `reloadPosition`,
`valueRepresentation`, `outputAlignment`) that are meaningful only for
specific functions. Always set `api_func` first, then read which of these
are enabled via `get_param(...,'DialogParameters')`.

---

## 2. The `MotorControl` Block -- Complete Behavioral Model

**One `MotorControl` block = one `MotorControl_*` function call.** The
block has `MaskType = s32k3_motorcontrol`. A MotorControl drive in a
model is composed of several blocks with different `api_func` values.

### 2.1 The `api_func` enum -- the function selector

**Always read the live `api_func.Enum`** via
`get_param({blk}, 'DialogParameters')`. The following are illustrative
(verified on S32K3 MBDT 1.8.0):

- `MotorControl_Enable` / `MotorControl_Disable` -- start/stop the drive
- `MotorControl_AlignmentStart` / `MotorControl_AlignmentSet` / `MotorControl_AlignmentFinish` -- rotor alignment sequence
- `MotorControl_CalibrationStart` / `MotorControl_CalibrationFinish` -- ADC offset calibration
- `MotorControl_GetAngleAndSpeed` -- read rotor angle and speed
- `MotorControl_GetAnalogInputs` -- read ADC results
- `MotorControl_GetDutyCycles` / `MotorControl_SetDutyCycles` -- duty-cycle R/W
- `MotorControl_GetFocState` -- read Field Oriented Control state
- `MotorControl_SetPwmFrequency` / `MotorControl_SetPwmFrequencyAndReload` -- PWM frequency control
- `MotorControl_SetDCurrent` / `MotorControl_SetDVoltage` / `MotorControl_SetQCurrent` / `MotorControl_SetQVoltage` -- current/voltage set-points
- `MotorControl_SetSpeed` -- speed set-point
- `MotorControl_GetVersionInfo` -- version query (no instance needed)

Selecting `api_func` reshapes the S-Function ports. **Set `api_func` first.**

### 2.2 Parameter surface

| Name | Type | Semantics | Meaningful for |
|---|---|---|---|
| `api_func` | enum | Function selector (Sec.2.1) | All |
| `instance` | enum | Logical MotorControl instance | All functions except `GetVersionInfo` |
| `paramInterpret` | enum (`ABSOLUTE`, `RELATIVE`) | Interpretation of angle/speed parameters | Select functions |
| `reloadPosition` | enum (`FRAME_AND_CENTER`, `FRAME`) | PWM reload position | `SetPwmFrequency*` |
| `valueRepresentation` | enum (`ELECTRIC`, `MECHANICAL`) | Angle/speed representation | `GetAngleAndSpeed`, `SetSpeed` |
| `outputAlignment` | enum (`LATEST`, `ONTRIGGER`) | Output alignment timing | Select functions |
| `text` | string | System-managed cache -- **never set** | Read-only |

### 2.3 The `instance` enum

Populated by the config tool (Peripherals -> MotorControl). When empty
the enum holds `"No Instances configured"` -- a sentinel, not a valid
selection. Route to `opening-mbdt-config-tool`.

### 2.4 Sentinel rules

| `api_func` | `instance` sentinel = error? |
|---|---|
| `MotorControl_GetVersionInfo` | NO -- no instance needed |
| All others | YES |

### 2.5 Port signatures per `api_func`

Port types are function-dependent and vary by `api_func`.
**Always read live after setting `api_func`** -- ports change with function selection.
Port data types not verified live; read from block after setting `api_func`.

| `api_func` | Inputs | Outputs |
|---|---|---|
| `MotorControl_Enable` / `MotorControl_Disable` | none | y1: status |
| `MotorControl_AlignmentStart` | none | y1: status |
| `MotorControl_AlignmentSet` | u1: angle, u2: current | y1: status |
| `MotorControl_AlignmentFinish` | none | y1: status |
| `MotorControl_CalibrationStart` / `MotorControl_CalibrationFinish` | none | y1: status |
| `MotorControl_GetAngleAndSpeed` | none | y1: angle, y2: speed |
| `MotorControl_GetAnalogInputs` | none | y1: analog input vector |
| `MotorControl_GetDutyCycles` | none | y1: duty cycle vector |
| `MotorControl_SetDutyCycles` | u1: duty cycle vector | y1: status |
| `MotorControl_GetFocState` | none | y1: FOC state |
| `MotorControl_SetPwmFrequency` | u1: frequency | y1: status |
| `MotorControl_SetPwmFrequencyAndReload` | u1: frequency, u2: reload value | y1: status |
| `MotorControl_SetDCurrent` | u1: d-axis current setpoint | y1: status |
| `MotorControl_SetQCurrent` | u1: q-axis current setpoint | y1: status |
| `MotorControl_SetDVoltage` | u1: d-axis voltage setpoint | y1: status |
| `MotorControl_SetQVoltage` | u1: q-axis voltage setpoint | y1: status |
| `MotorControl_SetSpeed` | u1: speed setpoint | y1: status |
| `MotorControl_GetVersionInfo` | none | y1: version info |

> **Note:** Exact port widths, data types, and output count depend on the
> `paramInterpret`, `valueRepresentation`, and `outputAlignment` parameters.
> Read live from the block after setting all parameters.

### 2.6 Selection ordering

1. `api_func` first.
2. `instance` next.
3. `paramInterpret`, `reloadPosition`, `valueRepresentation`, `outputAlignment` last (only those enabled after `api_func` set).

One `set_param` per parameter.

---

## 3. Required Block Catalog

| Block name | Library | Role |
|---|---|---|
| `MotorControl` | `mbd_s32k3_cdd_library` | Wraps one `MotorControl_*` function; multiple instances per model |

No dedicated ISR-handler block for MotorControl -- control-loop callbacks
are typically driven by a timer or ADC trigger, wired via the standard
`Hardware_Interrupt_Handler` block with the appropriate `irqGroup`.

---

## 4. Configuration Workflow

### 4.1 Pins
Route eMIOS PWM outputs, ADC inputs, encoder inputs per instance.
Pin numbers are board-specific -- discover via `nxp_s32ct_inspect(kind='pins')`.

### 4.2 Peripherals -> MotorControl
Declare each logical MotorControl instance. The **exact names** assigned
here become entries in the `instance` enum (case-sensitive, 1:1).

### 4.3 Board Initialization (Simulink model)

Add via [`editing-mbdt-board-init`](../../editing-mbdt-board-init/SKILL.md):

```
Component : MotorControl
Priority  : (verify live)
Enabled   : true
Header    : #include "MotorControl.h"
Code      : MotorControl_Init(&MotorControl_Config);
```

AUTOSAR standard driver. `MotorControl_Config` is emitted by the
code-gen tool from Peripherals -> MotorControl. Priority and exact
config symbol must be verified live via `get_mbdt_board_init(modelName)`
(the MCP tool takes only `modelName` -- do **not** pass a `platform`
argument) -- do not carry them from memory.

#### Expected generated C files

A correctly-configured MotorControl peripheral must cause the config
tool to emit these generated units. If any are missing, the build fails
at compile/link time -- authoritative evidence of a config-tool-side
problem, NOT a model problem. Confirm the exact file names against the
generated `{model}_Config/` folder -- do not cite from memory.

| Generated file | Emitted from | Flavor |
|---|---|---|
| `MotorControl_Cfg.h` / `MotorControl_PBcfg.*` | Peripherals -> MotorControl (always) | MotorControl driver |

**If `fatal error: MotorControl_Cfg.h` No such file appears at build
time:** the MotorControl flavor was not emitted. Do NOT touch the model.
Run `nxp_s32ct_validate(project_path={.mex}, tool_name="Peripherals")`,
read the parsed problems, and re-generate.

#### RTD documentation

Read the **UM** and the **IM** before modifying the external
configuration tool project, or before implementing a user request the
shipped examples do not cover. The **UM** tells you how each `api_func`
behaves; the **IM** covers generated-file expectations, init order, and
NVIC prerequisites. `{s32k3_root}` = `mbd_find_s32k3_root()`:

```
{s32k3_root}\S32K3_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\MotorControl_TS_T40D*_M70I*_R0\doc\
    RTD_MOTORCONTROL_IM.pdf   RTD_MOTORCONTROL_UM.pdf
```

Read UM before selecting `api_func`; read IM for init-order and
generated-file requirements.

### 4.4 Model Runtime Blocks
Assemble per Sec.6. Minimum: Enable block in Initialize Function,
control-loop blocks in the periodic task.

---

## 5. Initialize Function Pattern

Place at minimum:
1. `MotorControl_Enable` block (after calibration and alignment are
   complete, or unconditionally if alignment is not used).
2. Alignment sequence blocks if rotor alignment is required:
   `MotorControl_AlignmentStart` -> [wait] -> `MotorControl_AlignmentSet`
   -> `MotorControl_AlignmentFinish`.
3. Calibration blocks if ADC offset calibration is needed:
   `MotorControl_CalibrationStart` -> [wait] ->
   `MotorControl_CalibrationFinish`.

> **"wait" implementation note:** `Initialize Function` executes once at
> model start and **cannot block or delay**. Multi-step sequences
> (alignment, calibration) must be implemented using one of these patterns:
>
> - **Stateflow chart** inside the Initialize Function: model each step as
>   a state with an elapsed-time guard (e.g. after(50,msec)) before
>   transitioning to the next step.
> - **Polling across periodic task cycles**: call `AlignmentStart` in
>   Initialize Function; each periodic cycle check a status signal and
>   call `AlignmentSet` / `AlignmentFinish` once the status indicates
>   ready.
> - **Always check the shipped example** to see which pattern NXP uses
>   for the specific device -- do not assume either pattern.

Read the shipped example's Initialize Function live -- do not assume
ordering or which functions are needed.

---

## 6. Runtime Data Flow

### 6.1 Scheduling / trigger

The control-loop blocks run inside a **Function-Call Subsystem** triggered
at the user's chosen control-loop rate. **Always ask the user for the desired
rate before creating the subsystem** — do not assume a value. Typical ranges:
inner current loop = PWM switching frequency (8–20 kHz for PMSM); outer
speed/position loop = 1–4 kHz. Use the answer to name the subsystem and set
the Pulse Generator period (simulation) or timer period (on-target).
The trigger source is one of:

- A `Hardware_Interrupt_Handler` block with `irqGroup=Gpt` (timer-based,
  most common) or `irqGroup=Adc` (ADC end-of-conversion triggered).
- A `Pulse Generator` block (simulation / host testing only -- not for
  embedded deployment; replace with `Hardware_Interrupt_Handler` before build).

The `Initialize Function` subsystem runs once at startup; it must complete
before the periodic task fires. Do **not** place control-loop blocks
(GetAngleAndSpeed, SetSpeed, etc.) inside Initialize Function.

```
Root level
  Initialize  (Initialize Function subsystem)
    MotorControl_Enable  [+ alignment/calibration if required]

  StepControl   (Function-Call Subsystem, name reflects user-chosen rate)
    trigger <-- Hardware_Interrupt_Handler (irqGroup=Gpt | Adc)
    MotorControl_GetAngleAndSpeed  --> angle, speed signals
    MotorControl_GetAnalogInputs   --> current/voltage measurements
    [FOC algorithm subsystem]
    MotorControl_SetQCurrent / SetSpeed / SetDutyCycles  --> drive commands
```

### 6.2 Duty-cycle open-loop variant

```
Initialize Function:
  MotorControl_Enable

Step function:
  MotorControl_SetDutyCycles  (duty cycles from upstream algorithm)
  MotorControl_GetDutyCycles  (readback / verification, optional)
```

---

## 7. Interrupt Dependencies

MotorControl does not require a dedicated `Hardware_Interrupt_Handler`
for its core control loop -- the control-loop task is typically triggered
by a timer interrupt (GPT or eMIOS) or an ADC end-of-conversion. Wire
that trigger via `Hardware_Interrupt_Handler` with the appropriate
`irqGroup` (e.g. `irqGroup=Gpt` or `irqGroup=Adc`), not
`irqGroup=MotorControl`.

If the CDD emits MotorControl-specific notifications, `irqGroup=MotorControl`
is the correct selection on `Hardware_Interrupt_Handler`. Read the live
`irqHandlers` enum after setting `irqGroup=MotorControl` to discover
available handlers.

---

## 8. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| Instance logical name | Peripherals -> MotorControl | `instance` enum on block |
| PWM/ADC/encoder pin routing | Pins | Compiled-in; not exposed |
| Clock source | Peripherals -> MotorControl | Compiled-in; not exposed |
| NVIC enable | Platform -> Interrupt Controller | Manifests as task firing |
| Board-init entry | `editing-mbdt-board-init` skill | Emitted into `mbdt_board_init.c` |

---

## 9. Common Usage Patterns

**Pattern A -- Outer speed loop (velocity controller)**
```
Init: AlignmentStart -> [wait] -> AlignmentSet -> AlignmentFinish -> Enable
Loop (slower, e.g. speed-loop rate):
  GetAngleAndSpeed -> [speed PI controller] -> SetSpeed
```

**Pattern B -- Inner current loop (FOC, faster rate)**
```
Init: CalibrationStart -> [wait] -> CalibrationFinish
      AlignmentStart -> [wait] -> AlignmentSet -> AlignmentFinish -> Enable
Loop (faster, e.g. = PWM switching frequency):
  GetAngleAndSpeed + GetAnalogInputs
  -> [Park/Clarke transform + current PI]
  -> SetQCurrent + SetDCurrent
```
Note: `SetSpeed` sets a speed reference for an outer loop; `SetQCurrent` /
`SetDCurrent` command the inner current loop directly. Ask the user which
loop topology they need before selecting blocks.

**Pattern C -- Duty-cycle open loop**
```
Init: Enable
Loop: SetDutyCycles (from lookup table or upstream algorithm)
      GetDutyCycles (readback / verification, optional)
```

**Pattern D -- Multi-motor (dual-instance, e.g. S32K358)**
```
Each instance configured separately in S32CT (see Sec.11).
Each MotorControl_* block carries its own 'instance' selection.
Both instances can share the same task trigger or run at different rates.
```

**Pattern E -- Diagnostic / version query**
```
Any context: MotorControl_GetVersionInfo (no instance required)
```

---

## 10. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `instance` enum = `"No Instances configured"` | Config tool has no MotorControl instance | Open config tool; add instance in Peripherals -> MotorControl |
| Build links but motor never runs | Missing board-init entry | Verify `MotorControl_Init` via `get_mbdt_board_init` |
| Alignment never completes | AlignmentFinish not called / timing wrong | Add AlignmentFinish block; verify sequencing |
| `MotorControl_GetVersionInfo` works but other functions fail | `instance` sentinel not resolved | Configure instance in S32CT |
| Build fails: unresolved `MotorControl_Init` | Missing board-init | Add via `editing-mbdt-board-init`. Never stub. |

---

## 11. Multi-Motor Configuration (Dual-Instance)

Some S32K3 devices (e.g. S32K358) provide two independent sets of
motor-control hardware and support two logical MotorControl instances.

**S32CT configuration:**
- Declare two instances in Peripherals -> MotorControl (e.g. `MC0`, `MC1`).
- Assign independent eMIOS channel groups, ADC groups, and encoder inputs
  to each instance.

**Simulink model:**
- Each `MotorControl_*` block selects its own instance via the `instance`
  enum. Use descriptive block names (e.g. `MC0_GetAngleAndSpeed`,
  `MC1_GetAngleAndSpeed`) to avoid confusion.
- Both instances can share the same Function-Call Subsystem task (same
  trigger) or run in separate tasks at different rates -- the CDD is
  re-entrant per instance.
- Board-init emits one `MotorControl_Init` call per instance; verify both
  are present via `get_mbdt_board_init(modelName)`.

**Guardrail:** Never share one `instance` selection across blocks that
belong to different physical motors. Verify the instance-to-block mapping
by inspecting the `instance` enum value on every block after configuration.

---

## 12. Board-Specific Considerations

- S32K3-specific block. Always confirm availability via
  `get_mbdt_toolbox('s32k3','blocks')`.
- Pin assignments for PWM outputs, ADC inputs, and encoder signals are
  board-specific; never invent them. Read the shipped example `.mex`.

---

## 13. Guardrails (MotorControl-specific)

Generic block rules (no stubs, no invented names, interrupts only via the
ISR-handler block, `api_func` first, never set `text`) are in
[`../SKILL.md`](../SKILL.md); only MotorControl-specific rules follow.

- **S32K3 only.** The block does not resolve on other families; verify the
  family via `get_mbdt_toolbox`.
