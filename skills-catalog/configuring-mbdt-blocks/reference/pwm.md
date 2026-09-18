# PWM -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the PWM
peripheral on any NXP MBDT-targeted Simulink model. Covers the `Pwm`
block (`MaskType = {family}_pwm`), the channel-based duty/period runtime
pattern, the per-channel edge-notification ISR wiring, the eMIOS
component relation inside the config project, and the
external-config-tool dependencies. The behavioral model is expected to
hold cross-family (S32K3); exact enum labels
and board-init symbols may differ per family and are verified only on
S32K3 (RTD, MATLAB R2026a). Sections run in order: *what PWM is* ->
*block model* -> *config tool* -> *board init* -> *init arming* ->
*runtime updates* -> *interrupts*, then correlation matrix,
troubleshooting, and guardrails.

## The three PWM invariants (referenced throughout)

Three facts govern every PWM decision below. They are stated once here
and referenced by name; later sections do not re-derive them.

- **INV-1 -- PWM is channel-based and eMIOS-backed.** A waveform is
  driven per **channel** (`PwmChannel_N`), the single resource handle for
  duty, period, output, and notification -- there is no
  HW-unit -> group -> channel hierarchy as in ADC. Each channel is
  declared **under an eMIOS instance** (`PWM_EMIOS_INSTANCE_N`) inside the
  config project; the eMIOS instance, its unified-channel index, class
  (edge/center-aligned), default period/duty, polarity, and prescaler are
  all **config-tool-owned** and surface only in the `.mex` (see the
  canonical tree in Sec.2.3). The block exposes only the logical
  `PwmChannel_N` name plus a `moduleId` selector; everything behind them
  must be **read live, never assumed**.

- **INV-2 -- No mandatory Initialize Function block.** Unlike ADC
  (`Adc_SetupResultBuffer` is mandatory), a basic PWM design needs nothing
  in the Initialize Function -- `Pwm_Init` from board-init (Sec.4.5)
  starts every channel at its configured default duty/period at boot.
  `Pwm_EnableNotification` is added **only** for edge-interrupt designs.
  A duty/period-only model is complete with just runtime
  `Pwm_SetDutyCycle` blocks and no init-function block.

- **INV-3 -- Notification is a per-channel edge callback, routed only
  through the ISR handler.** `irqHandlers` under `irqGroup = Pwm`
  enumerates *per-channel* callbacks (`PwmChannel_N_Callback`) -- one entry
  per configured channel. The edge that raises it (rising / falling /
  both) is chosen per block via the `notification` enum, but the routing
  itself **never** goes through a parameter on the `Pwm` block: it always
  flows through a `Hardware_Interrupt_Handler`. There is no `isr_*` /
  `callback_*` parameter on `{family}_pwm`.

> **Tip -- start from a shipped example.** Open a shipped PWM example via
> [`opening-mbdt-example`](../../../opening-mbdt-example/SKILL.md); its
> `.mex` project (Pins -> eMIOS channel outputs, Peripherals -> Pwm,
> Peripherals -> Mcl for eMIOS master-bus / TRGMUX / LCU routing,
> Platform -> NVIC) plus its model (board init, top-level
> `Pwm_SetDutyCycle` / `Pwm_SetPeriodAndDuty`, optional edge-notification
> ISR handler) forms a coherent end-to-end reference that mirrors the
> sections below. Always confirm behavior against a current model via
> live discovery (`get_mbdt_toolbox(family, 'examples')`,
> `get_param(..., 'DialogParameters')`, `nxp_s32ct_inspect`) -- never
> carry example names, channel names, or callback strings from memory.

---

## 1. Peripheral Overview

Adding "PWM to a model" means placing several artefacts, not one block:

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT / EB tresos project (Pins -> eMIOS channel outputs, Peripherals -> Pwm, Platform -> NVIC; optionally Mcl for eMIOS master-bus / TRGMUX / LCU) | External to the model | External config tool |
| 2 | Board-init entry `Pwm_Init(&Pwm_Config)` | `mbdt_board_init.c`, emitted at code-gen | `editing-mbdt-board-init` skill |
| 3 | Initialize Function blocks (optional): `Pwm_EnableNotification` (edge-interrupt mode) | Simulink model | This skill |
| 4 | Runtime blocks: `Pwm_SetDutyCycle` / `Pwm_SetPeriodAndDuty` + (edge-interrupt mode) `Hardware_Interrupt_Handler` routing a `PwmChannel_N_Callback` | Simulink model | This skill |

**Silent failure modes if any is missing:**

- Missing (1) -> block enums resolve to `"No ... configured"` sentinels
  on `channel` / `moduleId`; the channel has no backing eMIOS instance
  (INV-1).
- Missing (2) -> build links but every `Pwm_*` call is a no-op; no
  waveform is ever produced.
- Missing (3) -> INV-2/INV-3: in edge-interrupt mode the per-channel
  notification never fires (a duty/period-only design does not need it).
- Missing (4) -> the driver runs at its configured default duty/period
  but the application never updates it; no dynamic waveform.

**How PWM differs from other peripherals:** it is **channel-based** and
**eMIOS-backed** (INV-1) -- a single `PwmChannel_N` handle, not a
group/HW-unit hierarchy; it has **no mandatory init-function block**
(INV-2), because `Pwm_Init` already starts the waveform at its default;
its notification is a **per-channel edge callback** routed only through
the ISR handler (INV-3). PWM is also frequently a **trigger SOURCE** for
other peripherals: a PWM / eMIOS edge routed through TRGMUX -> LCU -> BCTU
cross-triggers the ADC (Sec.6.4, `adc.md` Sec.6.2). That routing lives in
the **Mcl** driver; the PWM side is only the edge source.

---

## 2. The `Pwm` Block -- Complete Behavioral Model

**One `Pwm` block = one `Pwm_*` function call.** Every block has
`MaskType = {family}_pwm` (e.g. `s32k3_pwm`) and is an `S-Function`. A
PWM peripheral in a model is composed of *several* `Pwm` blocks with
different `api_func` values.

### 2.1 The `api_func` enum -- the function selector

**Always read the live `api_func.Enum`** via
`get_param({pwmBlk}, 'DialogParameters')` -- the set of available
`Pwm_*` functions is owned by the installed toolbox version and must
never be carried from memory. Whenever this reference names a specific
`Pwm_*` function, treat it as an **illustrative** label observed in the
shipped S32K3 examples; validate it against the block's live
`api_func.Enum` before selecting, and refuse near-misses.

Observed live entries on S32K3 (illustrative):

```
Pwm_SetDutyCycle             Pwm_SetDutyCycle_NoUpdate    Pwm_SetPeriodAndDuty
Pwm_SetPeriodAndDuty_NoUpdate Pwm_SetDutyPhaseShift       Pwm_SyncUpdate
Pwm_SetChannelOutput         Pwm_SetOutputToIdle          Pwm_GetOutputState
Pwm_SetChannelDeadTime       Pwm_SetCounterBus            Pwm_SetClockMode
Pwm_SetTriggerDelay          Pwm_MaskOutputs              Pwm_UnMaskOutputs
Pwm_EnableNotification       Pwm_DisableNotification      Pwm_GetChannelState
Pwm_FastUpdateEnableOU       Pwm_FastUpdateDisableOU      Pwm_FastUpdateSetUCRegA
Pwm_FastUpdateSetUCRegB      Pwm_SetPowerState            Pwm_GetCurrentPowerState
Pwm_GetTargetPowerState      Pwm_PreparePowerState        Pwm_GetVersionInfo
```

**Behavioral facts (independent of the exact function list):**

- **`Pwm_SetDutyCycle`** updates the duty cycle of a channel, keeping the
  configured period. The most common runtime call.
- **`Pwm_SetPeriodAndDuty`** updates both the period and the duty of a
  channel in one call (only meaningful for a channel configured as
  variable-period).
- **`Pwm_SetDutyCycle_NoUpdate` / `Pwm_SetPeriodAndDuty_NoUpdate`** stage
  new values without an immediate hardware reload; a subsequent
  `Pwm_SyncUpdate` commits them synchronously across channels -- the
  basis for glitch-free multi-channel updates.
- **`Pwm_SetChannelOutput` / `Pwm_SetOutputToIdle`** force a channel's
  output to a fixed level / to its idle state.
- **`Pwm_MaskOutputs` / `Pwm_UnMaskOutputs`** gate a channel's output
  without disturbing the running counter -- used for safe-state control.
- **`Pwm_SetChannelDeadTime`** sets the dead-time for a complementary
  (motor-control) channel pair.
- **`Pwm_EnableNotification` / `Pwm_DisableNotification`** arm / disarm a
  channel's edge notification; the block's `notification` enum selects
  the edge (rising / falling / both). Call `Pwm_EnableNotification` at
  init for edge-interrupt designs (INV-3).
- **`Pwm_GetChannelState` / `Pwm_GetOutputState`** read the current
  duty / output level of a channel (diagnostic / feedback).
- **`Pwm_GetVersionInfo`** is diagnostic; needs no resource enum.
- Selecting `api_func` reshapes the S-Function's ports and toggles the
  visibility of every other parameter. **Set `api_func` first.**

### 2.2 Parameter surface (constant across all `api_func` values)

| Name | Type | Prompt | Semantics | Meaningful for |
|---|---|---|---|---|
| `api_func` | enum | Function | Function selector (see Sec.2.1) | All |
| `channel` | enum | Channel | `PwmChannel_N` -- the logical PWM channel handle | Channel-scoped functions (duty / period / output / notification / state) |
| `notification` | enum | Edge Notification Type | `PWM_RISING_EDGE` \| `PWM_FALLING_EDGE` \| `PWM_BOTH_EDGES` | `Pwm_EnableNotification` |
| `moduleId` | enum | Module Id | `PWM_EMIOS_INSTANCE_N` -- the eMIOS instance the channel lives on | Instance-scoped / fast-update functions |
| `prescalerType` | enum | Prescaler Type | `PWM_PRIMARY_PRESCALER` \| `PWM_ALTERNATIVE_PRESCALER` | `Pwm_SetClockMode` |
| `fault` | enum | Fault Interrupt Source | `PWM_FLEXPWM_{n}_FAULT_INPUT_{m}` -- a FlexPWM fault input | Fault-related functions |
| `text` | string | *(empty)* | System-managed cache -- **never set** | Read-only |

The parameter set is constant across `api_func`; the mask shows/enables
only those meaningful for the selected function. Read live which are
enabled after setting `api_func`.

### 2.3 The resource enums and the canonical `.mex` layout

Observed live entries on S32K3 (illustrative -- read live before use;
channel names are **application-chosen** and will differ per project):

```
channel       : PwmChannel_0 | PwmChannel_1 | ... | PwmChannel_8
notification  : PWM_RISING_EDGE | PWM_FALLING_EDGE | PWM_BOTH_EDGES
moduleId      : PWM_EMIOS_INSTANCE_0 | PWM_EMIOS_INSTANCE_1 | PWM_EMIOS_INSTANCE_2
prescalerType : PWM_PRIMARY_PRESCALER | PWM_ALTERNATIVE_PRESCALER
fault         : PWM_FLEXPWM_0_FAULT_INPUT_0..3 | PWM_FLEXPWM_1_FAULT_INPUT_0..3
```

Semantics:

```
PwmChannel_N          -> a logical PWM channel (application-named in the
                         config tool); the single handle for duty /
                         period / output / notification. NOT a fixed
                         string; the user can rename it freely.
PWM_EMIOS_INSTANCE_N  -> the eMIOS timer instance (eMIOS_0 / _1 / _2) the
                         channel is routed to
PWM_{edge}            -> which counter edge raises the channel notification
PWM_{prescaler}       -> which eMIOS prescaler tap clocks the channel
PWM_FLEXPWM_n_FAULT_INPUT_m -> a FlexPWM fault input line
```

**Canonical `.mex` layout (the single source rendering; all later
sections back-reference this).** The channel names are NOT stored on the
model and NOT fixed by the driver -- they are declared in the config-tool
project's Pwm config tree, nested under the eMIOS instance node, and must
be read from there (INV-1). Confirmed live on S32K3:

```
/Pwm/Pwm/PwmChannelConfigSet/        <- the Pwm driver channel config set
    PwmEmios_0 | PwmEmios_1 | ...     <- one node per eMIOS instance
                                         (maps to PWM_EMIOS_INSTANCE_N)
        PwmEmiosChannels_M            <- the eMIOS unified channels
                                         declared on that instance
                                         (e.g. PwmEmios_0/PwmEmiosChannels_17)
```

This is the **eMIOS component relation** (INV-1): PWM channels are
declared as children of eMIOS instances, so the block's `moduleId`
(`PWM_EMIOS_INSTANCE_N`) selects the parent node and `channel`
(`PwmChannel_N`) selects a channel under it. To read the live names for a
project:

- `nxp_s32ct_inspect(kind='instances')` -- locate the `type_id = Pwm`
  instance.
- `nxp_s32ct_inspect(kind='xrefs', root_filter='Pwm')` -- surfaces the
  `/Pwm/Pwm/PwmChannelConfigSet/PwmEmios_N/PwmEmiosChannels_M` element
  paths.

The physical eMIOS unified-channel number behind each logical
`PwmChannel_N` is config-tool-owned and not exposed on the block. The
`notification` / `prescalerType` / `fault` enums are fixed driver
enumerations; only `channel` (and, through it, `moduleId`) is
project-dependent.

### 2.4 Sentinel rules

| `api_func` | resource sentinel = error? |
|---|---|
| `Pwm_GetVersionInfo` | NO -- no resource needed |
| `Pwm_GetCurrentPowerState` / `Pwm_GetTargetPowerState` | NO -- power-agnostic diagnostics |
| Everything else | YES (on the `channel` / `moduleId` enum it actually uses) |

> **Open the block first -- the sentinel is often just stale.** The `Pwm`
> block is a **linked** library block; its resource enums are populated
> by a mask initialization callback that fires when the block dialog is
> *opened*. Reading an enum on a freshly loaded model can therefore
> return a cached `"No ... configured"` sentinel even when the config
> tool *has* declared the channel. When you hit a sentinel: first
> `open_system({pwmBlk})` + a short `pause(1)`, re-read the enum, and only
> if the resource is still absent route to `opening-mbdt-config-tool` to
> declare the missing channel in Peripherals -> Pwm under an eMIOS
> instance node.

### 2.5 Selection ordering

1. `api_func` first -- reshapes ports and toggles visibility.
2. `channel` (the primary resource handle) / `moduleId` (whichever the
   function uses).
3. `notification` for `Pwm_EnableNotification`; `prescalerType` for
   `Pwm_SetClockMode`; `fault` for fault functions.

One `set_param` per parameter. Setting a resource enum before `api_func`
leaves it on a stale hidden slot and the model is incoherent.

---

## 3. Required Block Catalog

| Block name | `MaskType` | Role |
|---|---|---|
| `Pwm` | `{family}_pwm` | Wraps one `Pwm_*` function; multiple instances per model |
| `Hardware_Interrupt_Handler` | `{family}_isr_handler` | Routes a per-channel edge notification into a function-call subsystem (edge-interrupt mode) |
| `Mcl` (optional) | `{family}_mcl` | Enables the eMIOS/LCU sync output that arms a TRGMUX/LCU/BCTU trigger chain -- **not** a `Pwm` block |
| `FreeMASTER Config` (optional) | `{family}_fm_config` | Plots / tunes duty over serial -- **not** a `Pwm` block |

Discover exact paths via `detect_mbdt_blocks({family})`. An
edge-interrupt model places **one** ISR-handler block per channel
notification in use.

---

## 4. Configuration Workflow (config tool)

Steps 4.1-4.4 happen in the external configuration tool; board init
(Sec.4.5) and the model runtime blocks (Sec.5, Sec.6) follow.

### 4.1 Pins

Route each eMIOS channel output pin used by a `PwmChannel_N`. Pin numbers
are **board-specific** -- never invent them. Discover the live pin
mapping via `nxp_s32ct_inspect(kind='pins')` on the `.mex`; the PWM
outputs surface as `eMIOS_{inst}` peripheral rows with
`emios_{inst}_ch_{idx}_{mode}` signals (e.g. `eMIOS_0` /
`emios_0_ch_17_y`).

### 4.2 Peripherals -> Pwm (declare the channels)

Under each eMIOS instance node (per the canonical `.mex` tree in
Sec.2.3), assign:

- the eMIOS instance (`PwmEmios_N`, maps to `PWM_EMIOS_INSTANCE_N`);
- the eMIOS unified channel (`PwmEmiosChannels_M`) with its class
  (edge-aligned / center-aligned / ...), default period/duty, polarity,
  prescaler, and optional channel notification;
- the logical channel handle (`PwmChannel_{name}`) exposed to the block.

The **exact string names** you assign here (`PwmChannel_0`, ...) are what
appear in the block's `channel` enum -- case-sensitive, 1:1. `type_id =
Pwm` (from `nxp_s32ct_inspect(kind='instances')`); the shipped examples
run the Pwm driver in `autosar` mode. Channel names are freely chosen by
the application -- read them live from the block enum, never assume a
fixed string.

### 4.3 Peripherals -> Mcl (trigger-chain / sync modes only)

If the PWM edge drives another peripheral (ADC cross-trigger via
TRGMUX -> LCU -> BCTU, or a synchronised multi-channel update through the
eMIOS master bus), that routing is declared in the **Mcl** driver, not
the Pwm driver. A trigger-chain build is confirmed in the shipped
examples by a large `Mcl` instance (`type_id = Mcl`, `mode = autosar`)
alongside the `Pwm` instance -- verify via
`nxp_s32ct_inspect(kind='instances')`. The eMIOS master-bus / LCU sync
output is enabled from the model by an `Mcl` block (e.g.
`Mcl_SetLcuSyncOutputEnable`), not by any `Pwm` block. See `adc.md`
Sec.6.2 for the full PWM -> TRGMUX -> LCU -> BCTU -> ADC chain.

### 4.4 Platform -> Interrupt Controller (edge-interrupt mode only)

Enable the NVIC entry for each eMIOS instance whose channel notification
the model consumes. Verify the exact IRQn names via the `.mex` Platform
inspection -- do not assume. A duty/period-only design (INV-2: no
`Pwm_EnableNotification`, no ISR handler) does not require NVIC
enablement.

### 4.5 Board Initialization (Simulink model)

Add via [`editing-mbdt-board-init`](../../../editing-mbdt-board-init/SKILL.md):

```
Component : Pwm
Priority  : 100
Enabled   : true
Header    : #include "Pwm.h"
Code      : Pwm_Init(&Pwm_Config);
```

AUTOSAR standard driver (`mode = autosar` in the `.mex`). `Pwm_Config` is
emitted by the code-gen tool from Peripherals -> Pwm. Priority 100 is the
default emitted for the shipped example -- verify live via
`get_mbdt_board_init({family})`.

#### Expected generated C files (PWM)

A correctly-configured PWM peripheral must cause the config tool to emit
these generated units. If any are missing, the build fails at
compile/link time -- authoritative evidence of a config-tool-side
problem, NOT a model problem. Confirm the exact file names against the
generated `{model}_Config/` folder or the RTD Pwm component docs -- do
not cite from memory.

| Generated file | Emitted from | Flavor |
|---|---|---|
| `Pwm_Cfg.h` / `Pwm_PBcfg.*` | Peripherals -> Pwm (always) | PWM driver |
| `Emios_Pwm_Ip_Cfg.h` / `Emios_Pwm_Ip_Cfg.c` | Peripherals -> Pwm, per eMIOS instance | eMIOS PWM IP |

**If `fatal error: Pwm_Cfg.h` (or `Emios_Pwm_Ip_Cfg.h`) No such file
appears at build time:** the PWM flavor was not emitted. Do NOT touch the
model. Run `nxp_s32ct_validate(project_path={.mex}, tool_name="Peripherals")`,
read the parsed problems, and re-generate.

#### RTD documentation (Integration + User Manual)

Read the **UM** and the **IM** before you modify the external
configuration tools project (S32CT / EB tresos), or before you implement
a user request the shipped examples do not cover. The **UM** tells you
how each `api_func` behaves, so you pick and drive the right function;
the **IM** covers generated-file expectations, init order, and NVIC
prerequisites. `{family_root}` = `mbd_find_{family}_root()`; glob RTD-
version segments (filenames are uppercased):

```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Pwm_TS_T40D*_M70I*_R0\doc\
    RTD_PWM_IM.pdf   RTD_PWM_UM.pdf
```

When the PWM edge drives a trigger chain or a synchronised multi-channel
update, that routing lives in the **Mcl** driver (Sec.4.3, 6.5). Consult
the Mcl IM/UM as well:

```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Mcl_TS_T40D*_M70I*_R0\doc\
    RTD_MCL_IM.pdf   RTD_MCL_UM.pdf
```

---

## 5. Initialize Function Pattern


A basic PWM design needs **nothing** in the Initialize Function (INV-2):
`Pwm_Init` runs from `mbdt_board_init.c` (Sec.4.5) at boot and starts
each channel at its configured default duty/period. **The Initialize
Function does not call `Pwm_Init`.**

For an edge-interrupt design, arm the per-channel notification at init
(channel names below are placeholders -- read the live enum):

```
Event Listener (EventType = Initialize)
    +-- Pwm_GetVersionInfo        (optional, diagnostic)
    +-- Pwm_EnableNotification    channel = {PwmChannel_0}, notification = PWM_BOTH_EDGES
    +-- Pwm_EnableNotification1   channel = {PwmChannel_1}  (one per channel notified)
```

Read the example's Initialize Function live -- do not assume.

---

## 6. Runtime Data Flow and Usage Patterns

Once `Pwm_Init` (board-init) has produced a running waveform, the model
updates it in one of a few ways. Channel names below are placeholders --
read them live from the block enum.

### 6.1 Duty-cycle update (most common) -- no ISR

The default pattern: update duty every base-rate step. No
`Hardware_Interrupt_Handler` in the model and no NVIC enablement needed
(INV-2). Used for LED dimming, basic single- or multi-channel drives.

```
Top-level (runs at base rate)
   +-- Pwm_SetDutyCycle   channel = {PwmChannel_0}   <- new duty in
   +-- Pwm_SetDutyCycle1  channel = {PwmChannel_1}       (user logic -> duty port)
   +-- Pwm_SetDutyCycle2  channel = {PwmChannel_2}
```

`Pwm_Init` already produced a running waveform; each call just re-scales
its duty. Each channel is independent -- one `Pwm_SetDutyCycle` block per
channel.

### 6.2 Variable-period drive

Only for a channel configured as variable-period in Peripherals -> Pwm; a
fixed-period channel ignores the period argument.

```
Top-level
   +-- Pwm_SetPeriodAndDuty  channel = {PwmChannel_0}   <- period + duty ports
```

### 6.3 Synchronised multi-channel update -- staged + committed

Used when several channels must change duty on the same counter reload
(e.g. multi-phase drives) to avoid inter-channel glitches: stage each
channel with a `_NoUpdate` variant, then commit all at once with one
`Pwm_SyncUpdate` on the shared eMIOS instance.

```
Top-level
   +-- Pwm_SetDutyCycle_NoUpdate  channel = {PwmChannel_0}   -- stage
   +-- Pwm_SetDutyCycle_NoUpdate1 channel = {PwmChannel_1}   -- stage
   +-- Pwm_SyncUpdate             moduleId = PWM_EMIOS_INSTANCE_0  -- commit all
```

### 6.4 Edge-notification (interrupt) mode -- notify on counter edge

Arm the notification at init (INV-3), then route the edge through an ISR
handler for per-edge bookkeeping (cycle counter, phase bookkeeping,
etc.).

```
Initialize Function
   +-- Pwm_EnableNotification  channel = {PwmChannel_0}, notification = PWM_RISING_EDGE

Top-level
   +-- Pwm_SetDutyCycle        channel = {PwmChannel_0}

Counter edge -> per-channel notification -> NVIC -> ISR
   Hardware_Interrupt_Handler  irqGroup = Pwm, irqHandlers = {PwmChannel_0_Callback}
        | function-call trigger
        v
   Triggered Subsystem
        +-- (user logic: cycle counter, phase bookkeeping, etc.)
```

Each configured channel that raises a notification gets its own
`Hardware_Interrupt_Handler` + triggered-subsystem pair (Sec.7). The
callback name is `PwmChannel_N_Callback`, derived by the config tool from
the channel -- read `irqHandlers.Enum` live, never assume the string.

### 6.5 PWM as an ADC cross-trigger source (hardware trigger chain)

A PWM/eMIOS edge can arm an ADC conversion entirely in silicon, with no
software `Pwm_*` runtime call driving it: the edge is routed
`PWM/eMIOS -> TRGMUX -> LCU -> BCTU -> ADC`. That routing is owned by the
**Mcl** driver (Sec.4.3), the LCU sync output is enabled by an `Mcl`
block, and the ADC side is armed with `Adc_EnableHardwareTrigger` /
drained via the CTU family. See `adc.md` Sec.6.2 for the ADC-side detail.
On the PWM side there is nothing special to place beyond a normally
configured channel whose edge feeds the chain.

---

## 7. Interrupt Dependencies

1. **Edge-interrupt mode:** one `Hardware_Interrupt_Handler` **per
   channel notification** consumed.
2. **Duty/period-only mode:** no ISR handler in the model (INV-2).
3. **`irqHandlers.Enum` under `irqGroup = Pwm` enumerates all declared
   per-channel callbacks** (`PwmChannel_N_Callback`; INV-3). The exact
   callback strings are derived by the config tool from the
   application-chosen channel names -- **read the live `irqHandlers.Enum`,
   never assume**. The set grows with each channel you give a
   notification in the config tool.
4. NVIC enablement: enable the eMIOS instance IRQn per instance whose
   channel notification is consumed -- verify exact names via the `.mex`.

To wire a notification: add a `Hardware_Interrupt_Handler`, set
`irqGroup = Pwm`, then set `irqHandlers` to the exact channel callback
name from the live enum. PWM notifications **never** route through a
parameter on the `Pwm` block (INV-3); the `notification` enum on the
block only selects the *edge*, not the ISR routing.

---

## 8. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| Channel logical name (application-chosen) | Peripherals -> Pwm | `channel.Enum` on `Pwm` block |
| eMIOS instance the channel lives on | Peripherals -> Pwm (channel under eMIOS node) | `moduleId.Enum` (`PWM_EMIOS_INSTANCE_N`) |
| eMIOS unified channel index + class (edge/center-aligned) | Peripherals -> Pwm | Compiled-in; not exposed on block |
| Default period / duty / polarity | Peripherals -> Pwm | Compiled-in; not exposed |
| Channel notification enable + edge | Peripherals -> Pwm + block | Callback appears in `irqHandlers.Enum`; edge via `notification` on the block |
| Prescaler tap | Peripherals -> Pwm | `prescalerType` on `Pwm_SetClockMode` |
| FlexPWM fault input | Peripherals -> Pwm | `fault.Enum` on `Pwm` block |
| eMIOS clock source | Peripherals -> Pwm -> clock reference -> Mcu | Compiled-in; not exposed |
| eMIOS master-bus / TRGMUX / LCU routing | Peripherals -> Mcl | Enabled by an `Mcl` block; not on `Pwm` block |
| eMIOS output pin muxing | Pins | Compiled-in; not exposed |
| NVIC enable | Platform -> Interrupt Controller | Manifests as the channel callback firing |
| Power state target | Simulink model | `power_state`-style functions (`Pwm_SetPowerState`) |
| Board-init entry `Pwm_Init(&Pwm_Config)` | `editing-mbdt-board-init` skill | Emitted into `mbdt_board_init.c` |

### 8.1 Cross-component links inside the `.mex`

The Pwm driver does not stand alone: several other driver instances hold
**cross-references** (`value="/.../..."`) that wire the timing together
(all owned config-tool-side, visible only via
`nxp_s32ct_inspect(kind='xrefs')`). Read live -- never assume the exact
element names, which include application-chosen channel names.

| Link (source -> destination) | Reference path (destination) | Meaning |
|---|---|---|
| Pwm (internal) -> eMIOS channel | `/Pwm/Pwm/PwmChannelConfigSet/PwmEmios_N/PwmEmiosChannels_M` | The eMIOS component relation (INV-1) and the source of the block's `channel` / `moduleId` enums (Sec.2.3) |
| Pwm -> Mcu (clock) | `/Mcu/.../McuClockSettingConfig_0/...` (eMIOS clock) | The eMIOS clock source is owned by the Mcu clock tree, not the Pwm driver |
| Pwm -> EcuC (partition / core) | `/EcuC/.../EcucPartitionCollection_0/EcucPartition_N`, `/EcuC/.../EcucCoreDefinition_N` | Which core / OS partition the Pwm driver instance is bound to |
| Mcl -> eMIOS master bus | `/Mcl/Mcl/MclConfig/EmiosCommon_N/EmiosMclMasterBus_N` | The eMIOS master-bus / TRGMUX / LCU routing that lets a PWM edge cross-trigger the BCTU -> ADC chain (Sec.6.5); lives in the Mcl driver, large instance body |

None of these links is exposed on the `Pwm` block -- they are all
config-tool-owned and visible only via `.mex` xref inspection.

---

## 9. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `channel` / `moduleId` enum = "No ... configured" | Usually a **stale cached enum** on the linked block; only sometimes a genuinely undeclared channel | **First** `open_system({pwmBlk})` + `pause(1)` and re-read the enum (Sec.2.4). Only if still missing, open config tool via `opening-mbdt-config-tool` and add it in Peripherals -> Pwm |
| Build links but no waveform on the pin | Missing board-init entry `Pwm_Init(&Pwm_Config)`, or the eMIOS output pin not muxed | Verify `Pwm_Init` in board init (Sec.4.5); verify the pin in Pins (Sec.4.1). Never stub `Pwm_Init` |
| Waveform present but never changes duty | No runtime `Pwm_SetDutyCycle` block, or it never executes (INV-2: the default runs but is never updated) | Add a `Pwm_SetDutyCycle` at base rate feeding a live duty signal (Sec.6.1) |
| `Pwm_SetPeriodAndDuty` has no effect on period | Channel is not configured as variable-period | Set the channel to variable-period in Peripherals -> Pwm, or use `Pwm_SetDutyCycle` (Sec.6.2) |
| Multi-channel update glitches | Channels committed independently | Use `Pwm_SetDutyCycle_NoUpdate` on each + one `Pwm_SyncUpdate` (Sec.6.3) |
| Channel notification never fires | `Pwm_EnableNotification` missing, ISR handler missing, or eMIOS IRQn disabled (INV-3) | Add `Pwm_EnableNotification` at init; add the ISR handler (`irqGroup = Pwm`, correct `PwmChannel_N_Callback`); enable NVIC (Sec.4.4, 7) |
| ISR fires but wrong subsystem runs | `irqHandlers` set to the wrong channel's callback | Read `irqHandlers.Enum` live; pick the exact `PwmChannel_N_Callback` |
| ADC cross-trigger from PWM never converts | eMIOS master-bus / LCU routing not declared in Mcl, or LCU sync not enabled | Declare the routing in Peripherals -> Mcl; enable the LCU sync output via an `Mcl` block. See `adc.md` Sec.6.2 (Sec.6.5) |
| Build fails: unresolved `Pwm_Init` / `Pwm_SetDutyCycle` | Missing board-init entry | Add via `editing-mbdt-board-init`. Never stub the function |
| Build fails: `fatal error: Pwm_Cfg.h` / `Emios_Pwm_Ip_Cfg.h` No such file | Config tool did not emit the PWM config unit | Do NOT edit the model. Run `nxp_s32ct_validate(project_path={.mex}, tool_name="Peripherals")`; read problems; re-generate. See Sec.4.5 |

---

## 10. Board-Specific Considerations

- **eMIOS output pins vary per board.** Which physical pad backs each
  `PwmChannel_N` is board-specific -- verify against the model's `.mex`
  via `nxp_s32ct_inspect(kind='pins')` (the PWM outputs appear as
  `eMIOS_{inst}` peripheral rows with `emios_{inst}_ch_{idx}_{mode}`
  signals). Never invent pin numbers.
- **Channel labels are application-named** (INV-1). The `PwmChannel_N`
  names are strings chosen in Peripherals -> Pwm; the user can rename them
  freely. Read them live; do not assume any fixed naming scheme or that a
  channel maps to any fixed eMIOS channel number.
- **Channel-to-eMIOS-instance binding is config-tool-owned** (INV-1). The
  block sees `PwmChannel_N` and `PWM_EMIOS_INSTANCE_N`; the eMIOS unified
  channel index and class behind each channel live in the config tool
  (Sec.2.3, 8.1).
- **Cross-family portability.** The behavioral model (the live-discovered
  `api_func` set, the channel-based eMIOS-backed resource model,
  INV-1/INV-2/INV-3, per-channel edge notifications, ISR routing through
  the family handler, PWM as an ADC trigger source via Mcl). Family-specific differences to
  discover live:
  - board-init component name (`Pwm`) / header (`Pwm.h`) -- via
    `get_mbdt_board_init({family})`;
  - the timer that backs PWM -- other families may use a different timer
    IP than eMIOS, changing the `moduleId` labels and the
    `{IP}_Pwm_Ip_Cfg.*` generated-file name;

---

## 11. Guardrails (PWM-specific)

- **Never stub PWM functions.** Do not hand-write `Pwm_Init`,
  `Pwm_SetDutyCycle`, `Pwm_SetPeriodAndDuty`, any `Pwm_*Notification`, or
  any RTD function into generated C. The board-init entry (Sec.4.5) is
  what triggers MBDT to generate the driver code.
- **Never invent channel / eMIOS-instance names** (INV-1).
  `PWM_EMIOS_INSTANCE_0`, `PWM_RISING_EDGE`, `PWM_PRIMARY_PRESCALER` are
  exact strings from the config tool; channel names (`PwmChannel_N`) are
  application-chosen and vary per project. Read them all from the block's
  live enums.
- **Drive duty/period against a Channel.** `Pwm_SetDutyCycle` /
  `Pwm_SetPeriodAndDuty` take `channel`; the `moduleId` enum is only for
  the instance-scoped / sync / fast-update functions.
- **Match the update function to the channel's configured mode.** A
  fixed-period channel takes `Pwm_SetDutyCycle`; only a variable-period
  channel responds to `Pwm_SetPeriodAndDuty`. For glitch-free
  multi-channel updates use the `_NoUpdate` variants plus one
  `Pwm_SyncUpdate` (Sec.6.3).
- **No init-function block is mandatory** (INV-2); add
  `Pwm_EnableNotification` only for edge-interrupt designs.
- **Never route a PWM notification through a parameter on the `Pwm`
  block** (INV-3). All PWM edge notifications go through the
  `Hardware_Interrupt_Handler` block), and
  `irqHandlers` must be the exact live `PwmChannel_N_Callback` name.
- **PWM-as-trigger-source routing lives in Mcl, not Pwm.** The
  TRGMUX -> LCU -> BCTU -> ADC chain is owned by the Mcl driver; do not
  look for it on the `Pwm` block.
- **Set `api_func` first**, before any resource enum.
- **Never set `text` on any `Pwm` block** -- system-managed.
