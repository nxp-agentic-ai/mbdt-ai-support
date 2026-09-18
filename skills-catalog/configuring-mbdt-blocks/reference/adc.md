# ADC -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the ADC
peripheral on any NXP MBDT-targeted Simulink model. Covers the `Adc`
block (`MaskType = {family}_adc`), the HW-unit -> group -> channel
resource hierarchy, the initialize-then-convert runtime pattern, the
per-group / CTU notification ISR wiring, and the external-config-tool
dependencies. The behavioral model is expected to hold cross-family
(S32K3); exact enum labels and board-init
symbols may differ per family and are verified only on S32K3 (RTD,
MATLAB R2026a). Sections run in order: *what ADC is* -> *block model* ->
*config tool* -> *board init* -> *buffer setup* -> *runtime* ->
*interrupts*, then correlation matrix, troubleshooting, and guardrails.

## The three ADC invariants (referenced throughout)

Three facts govern every ADC decision below. They are stated once here
and referenced by name; later sections do not re-derive them.

- **INV-1 -- ADC is group-based, with a HW-unit -> group -> channel
  hierarchy.** A conversion is started and read against a **Group** (an
  application-named conversion group), which is bound to a **HW Unit**
  (`AdcHwUnit_N`) and carries an ordered list of **Channels**. You start
  conversions and read results per Group, not per channel -- there is no
  single flat channel handle as in PWM. The physical hardware unit /
  channel number behind each logical name, the group's channel list, its
  conversion mode (one-shot / continuous), and its trigger source are all
  **config-tool-owned** and surface only in the `.mex` (see the canonical
  tree in Sec.2.3). Group and channel names are application-chosen and
  must be **read live, never assumed**.

- **INV-2 -- A result buffer must be registered before any conversion.**
  `Adc_SetupResultBuffer` (in the Initialize Function) hands the driver
  the application-owned array it fills each conversion -- this is
  **mandatory**, once per Group, before any conversion runs. Without it
  the driver has no buffer to fill: `Adc_ReadGroup` returns stale /
  undefined data and, in interrupt mode, the group-end notification never
  fires. This is a runtime silence, not a build error. This is the ADC
  analogue of a mandatory init action (contrast PWM, which has none).

- **INV-3 -- Completion is a per-group / CTU notification, routed only
  through the ISR handler.** `irqHandlers` under `irqGroup = Adc`
  enumerates *per-group* end-of-conversion notifications plus watchdog,
  CTU new-data / list-last / overrun, and FIFO watermark notifications --
  one entry per configured group / CTU / FIFO. The routing **never** goes
  through a parameter on the `Adc` block: it always flows through a
  `Hardware_Interrupt_Handler`. There is no `isr_*` / `callback_*`
  parameter on `{family}_adc`. CTU (Cross Triggering Unit) is a distinct
  triggering mode with its own `api_func` family and its own BCTU HW
  unit / trigger / FIFO enums.

> **Tip -- start from a shipped example.** Open a shipped ADC example via
> [`opening-mbdt-example`](../../../opening-mbdt-example/SKILL.md); its
> `.mex` project (Pins -> ADC channels, Peripherals -> Adc, Peripherals ->
> Mcl for CTU / DMA, Platform -> NVIC) plus its model (board init,
> Initialize Function with `Adc_SetupResultBuffer`, top-level
> `Adc_StartGroupConversion`, group-end ISR handler, read-group
> subsystem) forms a coherent end-to-end reference that mirrors the
> sections below. Always confirm behavior against a current model via
> live discovery (`get_mbdt_toolbox(family, 'examples')`,
> `get_param(..., 'DialogParameters')`, `nxp_s32ct_inspect`) -- never
> carry example names, group names, or notification strings from memory.

---

## 1. Peripheral Overview

Adding "ADC to a model" means placing several artefacts, not one block:

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT / EB tresos project (Pins -> ADC channels, Peripherals -> Adc, Platform -> NVIC; optionally Mcl for CTU / DMA) | External to the model | External config tool |
| 2 | Board-init entry `Adc_Init(&Adc_Config)` | `mbdt_board_init.c`, emitted at code-gen | `editing-mbdt-board-init` skill |
| 3 | Initialize Function blocks: `Adc_SetupResultBuffer` (mandatory) + `Adc_EnableGroupNotification` (interrupt mode) | Simulink model | This skill |
| 4 | Runtime blocks: `Adc_StartGroupConversion` + (group-end mode) `Hardware_Interrupt_Handler` + a read subsystem calling `Adc_ReadGroup` | Simulink model | This skill |

**Silent failure modes if any is missing:**

- Missing (1) -> block enums resolve to `"No ... configured"` sentinels
  on `hw_unit` / `group` / `channel` (INV-1).
- Missing (2) -> build links but every `Adc_*` call is a no-op; no
  conversions ever happen.
- Missing (3) -> INV-2: `Adc_SetupResultBuffer` never runs, so the driver
  has no buffer to fill and `Adc_ReadGroup` returns stale / undefined
  data; in interrupt mode the group-end notification never fires.
- Missing (4) -> no conversion is ever started; no data flows.

**How ADC differs from other peripherals:** it is **group-based** with a
two-level HW-unit -> group -> channel hierarchy (INV-1), unlike the flat
channel handle of PWM / GPT -- you convert and read per Group; it
**mandates a result buffer** before any conversion (INV-2), where PWM has
no mandatory init action; and its completion is a **per-group / CTU
notification** routed only through the ISR handler (INV-3), with a
distinct **CTU** cross-triggering mode carrying its own BCTU resource
enums. ADC is frequently the **downstream target** of a hardware trigger
chain: a PWM / eMIOS edge routed through TRGMUX -> LCU -> BCTU
cross-triggers the ADC (Sec.6.2). That routing lives in the **Mcl**
driver; the ADC side arms with `Adc_EnableHardwareTrigger` / the CTU
family.

---

## 2. The `Adc` Block -- Complete Behavioral Model

**One `Adc` block = one `Adc_*` function call.** Every block has
`MaskType = {family}_adc` (e.g. `s32k3_adc`) and is an `S-Function`. An
ADC peripheral in a model is composed of *several* `Adc` blocks with
different `api_func` values.

### 2.1 The `api_func` enum -- the function selector

**Always read the live `api_func.Enum`** via
`get_param({adcBlk}, 'DialogParameters')` -- the set of available
`Adc_*` functions is owned by the installed toolbox version and must
never be carried from memory. Whenever this reference names a specific
`Adc_*` function, treat it as an **illustrative** label observed in the
shipped S32K3 examples; validate it against the block's live
`api_func.Enum` before selecting, and refuse near-misses.

Observed live entries on S32K3 (illustrative):

```
Adc_SetupResultBuffer        Adc_StartGroupConversion    Adc_StopGroupConversion
Adc_ReadGroup                Adc_EnableHardwareTrigger   Adc_DisableHardwareTrigger
Adc_EnableGroupNotification  Adc_DisableGroupNotification Adc_GetGroupStatus
Adc_GetStreamLastPointer     Adc_GetVersionInfo          Adc_SetPowerState
Adc_GetCurrentPowerState     Adc_GetTargetPowerState     Adc_PreparePowerState
Adc_EnableChannel            Adc_DisableChannel          Adc_Calibrate
Adc_ConfigureThreshold       Adc_ReadRawData             Adc_EnableWdgNotification
Adc_DisableWdgNotification   Adc_Main_PowerTransitionManager   Adc_SetUserGainAndOffset
Adc_EnableCtuControlMode     Adc_DisableCtuControlMode   Adc_CtuEnableHwTrigger
Adc_CtuDisableHwTrigger      Adc_CtuStartConversion      Adc_CtuReadConvData
Adc_CtuReadConvResult        Adc_CtuReadFifoData         Adc_CtuReadFifoResult
Adc_CtuMasterReload
```

**Behavioral facts (independent of the exact function list):**

- **`Adc_SetupResultBuffer`** hands the driver the application array it
  fills on each conversion of a Group. Call once per Group in the
  Initialize Function, **before** any conversion (INV-2).
- **`Adc_StartGroupConversion` / `Adc_StopGroupConversion`** start / stop
  a software-triggered conversion of a Group.
- **`Adc_ReadGroup`** copies the most recent converted results for a
  Group out of the result buffer. Typically called from the group-end
  ISR subsystem (interrupt mode) or polled after `Adc_GetGroupStatus`.
- **`Adc_EnableGroupNotification` / `Adc_DisableGroupNotification`** arm /
  disarm the per-group end-of-conversion notification. Call
  `Adc_EnableGroupNotification` at init for interrupt-driven reads
  (INV-3).
- **`Adc_GetGroupStatus`** returns the conversion state of a Group
  (idle / busy / completed) -- the basis for a polling read.
- **`Adc_EnableHardwareTrigger` / `Adc_DisableHardwareTrigger`** arm a
  hardware-triggered Group (e.g. from a PWM / timer edge).
- **CTU family** (`Adc_EnableCtuControlMode`, `Adc_CtuStartConversion`,
  `Adc_CtuReadConvData` / `...Result`, `Adc_CtuReadFifoData` /
  `...Result`, `Adc_CtuMasterReload`) drives the ADC through the BCTU
  cross-triggering unit and its result FIFOs -- a distinct mode with its
  own resource enums (Sec.2.3; INV-3).
- **`Adc_Calibrate`** runs a self-calibration pass on a HW Unit.
- **`Adc_GetVersionInfo`** is diagnostic; needs no resource enum.
- Selecting `api_func` reshapes the S-Function's ports and toggles the
  visibility of every other parameter. **Set `api_func` first.**

### 2.2 Parameter surface (constant across all `api_func` values)

| Name | Type | Prompt | Semantics | Meaningful for |
|---|---|---|---|---|
| `api_func` | enum | Function | Function selector (see Sec.2.1) | All |
| `hw_unit` | enum | HW Unit | `AdcHwUnit_N` -- the logical ADC hardware unit | `Adc_Calibrate`, `Adc_SetPowerState`, HW-unit-scoped functions |
| `group` | enum | Group | an application-named conversion group bound to a HW Unit | `Adc_SetupResultBuffer`, `Adc_StartGroupConversion`, `Adc_StopGroupConversion`, `Adc_ReadGroup`, `Adc_*GroupNotification`, `Adc_GetGroupStatus`, `Adc_*HardwareTrigger` |
| `channel` | enum | Channel | `ADC_{name}` -- a single application-named logical channel | `Adc_EnableChannel`, `Adc_DisableChannel`, `Adc_ReadRawData` |
| `threshold_control` | enum | Threshold Control | Watchdog threshold-control handle | `Adc_ConfigureThreshold`, `Adc_*WdgNotification` |
| `power_state` | enum | Power State | `ADC_FULL_POWER` \| `ADC_LOW_POWER` \| `ADC_NODEFINE_POWER` | `Adc_SetPowerState`, `Adc_PreparePowerState` |
| `ctu_unit` | enum | CTU Unit | `BctuHwUnit_N` -- BCTU cross-triggering unit | CTU functions |
| `ctu_trigger` | enum | CTU Trigger | `AdcHwTrigger_N` -- a BCTU trigger index | `Adc_CtuEnableHwTrigger`, `Adc_CtuDisableHwTrigger`, `Adc_CtuStartConversion` |
| `ctu_fifo_idx` | enum | CTU FIFO | `BctuResultFifos_N` -- a BCTU result FIFO | `Adc_CtuReadFifoData`, `Adc_CtuReadFifoResult` |
| `text` | string | *(empty)* | System-managed cache -- **never set** | Read-only |

The parameter set is constant across `api_func`; the mask shows/enables
only those meaningful for the selected function. Read live which are
enabled after setting `api_func`.

### 2.3 The resource enums and the canonical `.mex` layout

Observed live entries on S32K3 (illustrative -- read live before use;
group and channel names are **application-chosen** and will differ per
project):

```
hw_unit           : AdcHwUnit_0 | AdcHwUnit_1 | AdcHwUnit_2
group             : {application-named groups, e.g. AdcGroup_0 | AdcGroup_1}
channel           : {application-named channels, e.g. ADC_POT_0 | TOUCHP_A}
threshold_control : (sentinel) "No ADC threshold control configured"
power_state       : ADC_FULL_POWER | ADC_LOW_POWER | ADC_NODEFINE_POWER
ctu_unit          : BctuHwUnit_0
ctu_trigger       : AdcHwTrigger_0 | AdcHwTrigger_1 | AdcHwTrigger_2
ctu_fifo_idx      : BctuResultFifos_0 | BctuResultFifos_1
```

Semantics:

```
AdcHwUnit_N   ->  a physical ADC hardware unit (ADC0 / ADC1 / ADC2)
{group name}  ->  a conversion group bound to a HW unit; carries an
                  ordered channel list. The group name is chosen by the
                  application in the config tool -- it is NOT a fixed
                  string; the user can rename it freely.
ADC_{name}    ->  a single logical channel (application-named)
BctuHwUnit_0  ->  the BCTU cross-triggering unit
AdcHwTrigger_N->  a BCTU trigger source index
BctuResultFifos_N -> a BCTU result FIFO
```

**Canonical `.mex` layout (the single source rendering; all later
sections back-reference this).** The group / channel names are NOT stored
on the model and NOT fixed by the driver -- they are declared in the
config-tool project's Adc config tree and must be read from there
(INV-1). Confirmed live on S32K3:

```
/Adc/Adc/AdcConfigSet/               <- the Adc driver config set
    AdcHwUnit_0 | AdcHwUnit_1 | ...   <- physical ADC hardware units
        {channel}                     <- channels nested under a HW unit
                                         (e.g. AdcHwUnit_1/ADC_POT_0)
        AdcThresholdControl_0         <- analog-watchdog threshold ctrl
    AdcGroup_0 | AdcGroup_1 | ...     <- application-named conversion
                                         groups (renamable), declared
                                         under AdcConfigSet
    AdcHwTrigger_0 | AdcHwTrigger_1   <- BCTU trigger indices (CTU mode)
```

This is the **group/HW-unit hierarchy** (INV-1): a `group` handle on the
block maps to an `AdcGroup_N` under `AdcConfigSet`, bound to an
`AdcHwUnit_N` which carries the nested channels. The group names read
there are exactly the strings that populate the block's `group.Enum` --
1:1, case-sensitive. To read the live names for a project:

- `nxp_s32ct_inspect(kind='instances')` -- locate the `type_id = Adc`
  instance.
- `nxp_s32ct_inspect(kind='xrefs', root_filter='Adc')` -- surfaces the
  `/Adc/Adc/AdcConfigSet/...` element paths.

The physical hardware unit / channel number behind each logical name is
config-tool-owned and not exposed on the block. The `power_state` and CTU
enums are fixed driver enumerations; `group`, `channel`, and (through the
hierarchy) `hw_unit` are project-dependent.

### 2.4 Sentinel rules

| `api_func` | resource sentinel = error? |
|---|---|
| `Adc_GetVersionInfo` | NO -- no resource needed |
| `Adc_GetCurrentPowerState` / `Adc_GetTargetPowerState` | NO -- power-agnostic diagnostics, no group/channel |
| `Adc_Main_PowerTransitionManager` | NO -- driver tick, no resource |
| Everything else | YES (on the resource enum(s) it actually uses) |

If `group.Enum` (or `hw_unit` / `channel` / `ctu_unit` / ...) reads
`"No ... configured"`, route to `opening-mbdt-config-tool` and declare
the missing element in Peripherals -> Adc. Note that `threshold_control`
legitimately reads `"No ADC threshold control configured"` on models that
do not use the analog watchdog -- that is expected, not an error, unless
you select a watchdog / threshold `api_func`.

> **Open the block first -- the sentinel is often just stale.** The `Adc`
> block is a **linked** library block; its resource enums are populated
> by a mask initialization callback that fires when the block dialog is
> *opened*. Reading an enum on a freshly loaded model can therefore
> return a cached `"No ... configured"` sentinel even when the config
> tool *has* declared the resource. When you hit a sentinel: first
> `open_system({adcBlk})` + a short `pause(1)`, re-read the enum, and only
> if the resource is still absent route to `opening-mbdt-config-tool`.

### 2.5 Selection ordering

1. `api_func` first -- reshapes ports and toggles visibility.
2. `hw_unit` / `group` / `channel` (whichever the function uses).
3. CTU enums (`ctu_unit` / `ctu_trigger` / `ctu_fifo_idx`) for CTU
   functions; `power_state` for power functions; `threshold_control` for
   watchdog functions.

One `set_param` per parameter. Setting a resource enum before `api_func`
leaves it on a stale hidden slot and the model is incoherent.

---

## 3. Required Block Catalog

| Block name | `MaskType` | Role |
|---|---|---|
| `Adc` | `{family}_adc` | Wraps one `Adc_*` function; multiple instances per model |
| `Hardware_Interrupt_Handler` | `{family}_isr_handler` | Routes a group-end / CTU / FIFO notification into a function-call subsystem (interrupt mode) |
| `Mcl` (optional) | `{family}_mcl` | Enables the LCU sync output / DMA that arms a TRGMUX/LCU/BCTU trigger chain -- **not** an `Adc` block |
| `FreeMASTER Config` (optional) | `{family}_fm_config` | Plots converted results over serial -- **not** an `Adc` block |

Discover exact paths via `detect_mbdt_blocks({family})`. A group-based
interrupt model places **one** ISR-handler block per group notification
in use; a CTU model places one per CTU / FIFO notification in use.

---

## 4. Configuration Workflow (config tool)

Steps 4.1-4.4 happen in the external configuration tool; board init
(Sec.4.5) and the model runtime blocks (Sec.5, Sec.6) follow.

### 4.1 Pins

Route each analog input pin used by a channel. Pin numbers are
**board-specific** -- never invent them. Discover the live pin mapping
via `nxp_s32ct_inspect(kind='pins')` on the `.mex`.

### 4.2 Peripherals -> Adc (declare the hierarchy)

Declare the full hierarchy (per the canonical `.mex` tree in Sec.2.3).
Assign, in order:

- the physical ADC hardware unit (`AdcHwUnit_N`) + resolution + clock +
  trigger source;
- a logical channel (`ADC_{channel}`; name it, bind it to an ADC input);
- the conversion group (`{group name}`) with its ordered channel list,
  trigger source (SW / HW / CTU), conversion mode (one-shot / continuous),
  and GroupNotification.

The **exact string names** you assign here (`AdcHwUnit_0`, the group
names, the channel names) are what appear in the block's resource enums
-- case-sensitive, 1:1. Group and channel names are freely chosen by the
application -- read them live from the block enum, never assume a fixed
string. `type_id = Adc` (from `nxp_s32ct_inspect(kind='instances')`); the
shipped examples run the Adc driver in `autosar` mode.

For CTU-triggered conversions also declare the BCTU unit, its triggers,
and result FIFOs (`BctuHwUnit_0`, `AdcHwTrigger_N`, `BctuResultFifos_N`).

### 4.3 Peripherals -> Mcl (CTU / DMA modes only)

If a Group or FIFO delivers results via DMA, declare the DMA channel(s)
in the **Mcl** driver; the Adc driver picks them up internally. CTU
streaming to a result FIFO is set up here together with Peripherals ->
Adc. A DMA-backed acquisition is confirmed in the shipped examples by an
`Mcl` instance (`type_id = Mcl`, `mode = autosar`) alongside the `Adc`
instance -- verify via `nxp_s32ct_inspect(kind='instances')`. In that
setup the ADC groups are **hardware-triggered** (from a PWM / timer edge,
often routed through TRGMUX / LCU), so the model arms them with
`Adc_EnableHardwareTrigger` (and disarms with
`Adc_DisableHardwareTrigger`) rather than `Adc_StartGroupConversion`; the
completed samples are moved into the result buffer by DMA and a per-group
end notification still fires. The DMA channel indices are
config-tool-owned and are not exposed on the `Adc` block.

### 4.4 Platform -> Interrupt Controller (interrupt / CTU modes only)

Enable the NVIC entry for each ADC hardware unit (and the BCTU, for CTU
mode) whose end-of-conversion notification the model consumes. Verify the
exact IRQn names via the `.mex` Platform inspection -- do not assume.
Pure polling mode (`Adc_GetGroupStatus` + `Adc_ReadGroup`) does not
require NVIC enablement.

### 4.5 Board Initialization (Simulink model)

Add via [`editing-mbdt-board-init`](../../../editing-mbdt-board-init/SKILL.md):

```
Component : Adc
Priority  : 50
Enabled   : true
Header    : #include "Adc.h"
Code      : Adc_Init(&Adc_Config);
```

AUTOSAR standard driver (`mode = autosar` in the `.mex`). `Adc_Config` is
emitted by the code-gen tool from Peripherals -> Adc. Priority 50 is the
default emitted for the shipped examples -- verify live via
`get_mbdt_board_init({family})`.

#### Expected generated C files (ADC)

A correctly-configured ADC peripheral must cause the config tool to emit
these generated units. If any are missing, the build fails at
compile/link time -- authoritative evidence of a config-tool-side
problem, NOT a model problem. Confirm the exact file names against the
generated `{model}_Config/` folder or the RTD Adc component docs -- do
not cite from memory.

| Generated file | Emitted from | Flavor |
|---|---|---|
| `Adc_Cfg.h` / `Adc_PBcfg.*` | Peripherals -> Adc (always) | ADC driver |
| `Adc_Ip_Cfg.h` / `Adc_Ip_Cfg.c` | Peripherals -> Adc, per HW unit | ADC IP |
| `Bctu_Ip_Cfg.*` | Peripherals -> Adc, CTU mode only | BCTU IP |

**If `fatal error: Adc_Cfg.h` (or `Adc_Ip_Cfg.h`) No such file appears at
build time:** the ADC flavor was not emitted. Do NOT touch the model.
Run `nxp_s32ct_validate(project_path={.mex}, tool_name="Peripherals")`,
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
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Adc_TS_T40D*_M70I*_R0\doc\
    RTD_ADC_IM.pdf   RTD_ADC_UM.pdf
```

For CTU / DMA-backed acquisitions, the **Mcl** driver holds the DMA
channel and the TRGMUX / LCU / BCTU trigger-chain routing (Sec.4.3,
Sec.6.2); it is documented in the Mcl PDFs:

```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Mcl_TS_T40D*_M70I*_R0\doc\
    RTD_MCL_IM.pdf   RTD_MCL_UM.pdf
```

---

## 5. Initialize Function Pattern


The shipped ADC examples place the mandatory buffer setup (INV-2) and the
notification arming in the Initialize Function, before any conversion
(group names below are placeholders -- read the live enum):

```
Event Listener (EventType = Initialize)
    +-- Adc_GetVersionInfo            (optional, diagnostic)
    +-- Adc_SetupResultBuffer   group = {AdcGroup_0}   (hand the driver its array)
    +-- Adc_SetupResultBuffer1  group = {AdcGroup_1}   (one per group in use)
    +-- Adc_EnableGroupNotification   group = {AdcGroup_0}   (interrupt mode only)
    +-- Adc_EnableGroupNotification1  group = {AdcGroup_1}
```

- `Adc_SetupResultBuffer` is **mandatory** for every group you read
  (INV-2); the driver has no default buffer.
- `Adc_EnableGroupNotification` is added only for interrupt-driven reads;
  a pure polling design omits it.
- **The Initialize Function does not call `Adc_Init`** -- that runs from
  `mbdt_board_init.c` (Sec.4.5) at boot, before the model's Initialize
  Function.
- For CTU mode, `Adc_EnableCtuControlMode` is placed here in addition to
  (or instead of) `Adc_EnableGroupNotification`. Read the example's
  Initialize Function live -- do not assume.

---

## 6. Runtime Data Flow and Usage Patterns

Once the buffer is set up (Sec.5), the model converts and reads in one of
a few ways. Group names below are placeholders -- read them live from the
block enum.

### 6.1 Group-notification (interrupt) mode -- start, ISR, read

The default interrupt pattern: arm at init, start at base rate, read in
the group-end ISR. Also covers multi-group acquisition -- one
`Adc_StartGroupConversion` and one ISR-handler + triggered-subsystem pair
per group.

```
Initialize Function
   +-- Adc_SetupResultBuffer      group = {AdcGroup_0}
   +-- Adc_EnableGroupNotification group = {AdcGroup_0}

Top-level (runs at base rate)
   +-- Adc_StartGroupConversion   group = {AdcGroup_0}   -- kick off a conversion
   +-- Adc_StartGroupConversion1  group = {AdcGroup_1}

Conversion completes -> group-end notification -> NVIC -> ISR
   Hardware_Interrupt_Handler  irqGroup = Adc, irqHandlers = {group-end notification}
        | function-call trigger
        v
   Triggered Subsystem
        +-- Adc_ReadGroup   group = {AdcGroup_0}   -- copy results out of the buffer
        +-- (user logic: scale, plot, drive PWM, etc.)
```

Each configured group that raises an end notification gets its own
`Hardware_Interrupt_Handler` + triggered subsystem pair (Sec.7). The
notification name is derived by the config tool from the group and its HW
unit -- read `irqHandlers.Enum` live, never assume the string.

### 6.2 CTU / streaming mode -- cross-triggered conversions and FIFO reads

```
Initialize Function
   +-- Adc_SetupResultBuffer      group = {AdcGroup_0}
   +-- Adc_EnableCtuControlMode   hw_unit = AdcHwUnit_0
   +-- Adc_EnableCtuControlMode1  hw_unit = AdcHwUnit_1

Top-level
   +-- Adc_CtuStartConversion     ctu_trigger = AdcHwTrigger_2   -- BCTU triggers the ADC

CTU new-data / list-last notification -> NVIC -> ISR
   Hardware_Interrupt_Handler  irqGroup = Adc, irqHandlers = {CTU notification}
        | trigger
        v
   Triggered Subsystem
        +-- Adc_CtuReadConvData   ctu_unit = BctuHwUnit_0   -- read a converted sample
        +-- (or Adc_CtuReadFifoData ctu_fifo_idx = BctuResultFifos_0 for FIFO streaming)
```

**Hardware trigger chain (PWM -> TRGMUX -> LCU -> CTU -> ADC).** A shipped
CTU example builds the full silicon trigger path without any software
`Adc_CtuStartConversion`: a PWM / eMIOS edge is routed through TRGMUX into
the LCU (Logic Control Unit), whose synchronised output arms the BCTU,
which cross-triggers the ADC hardware units. The TRGMUX / LCU / CTU
routing lives in the **Mcl** driver (`type_id = Mcl`, `mode = autosar`;
its instance body is large because it carries this routing plus any DMA
channels) -- verify via `nxp_s32ct_inspect(kind='instances')`. The LCU
sync output is enabled from the model by an `Mcl` block
(`MaskType = {family}_mcl`) calling `Mcl_SetLcuSyncOutputEnable`; this is
**not** an `Adc` block. In this fully hardware-triggered variant every
ADC HW unit is placed in CTU control mode at init
(`Adc_EnableCtuControlMode` on `AdcHwUnit_0` / `_1` / `_2`), the BCTU
hardware trigger is armed with `Adc_CtuEnableHwTrigger`, results are
drained with `Adc_CtuReadFifoResult` (`ctu_fifo_idx = BctuResultFifos_0`),
and the ISR fires on a BCTU FIFO watermark notification -- observed live
as a `Bctu_*` watermark notification (illustrative; read live). Note the
`Bctu_*` notification family sits under `irqGroup = Adc` alongside the
`Adc_*` group and CTU notifications (INV-3). See `pwm.md` Sec.6.5 for the
PWM-source side of this chain.

### 6.3 Polling mode -- no ISR

No `Hardware_Interrupt_Handler` in the model; no NVIC enablement needed.
Start, poll status, read when complete.

```
Top-level (base rate)
   +-- Adc_StartGroupConversion   group = {AdcGroup_0}
   +-- Adc_GetGroupStatus         group = {AdcGroup_0}   -- If (completed) ->
   +-- Adc_ReadGroup              group = {AdcGroup_0}   -- copy results
```

### 6.4 Per-channel and power / calibration control

Occasional non-group operations: single-channel raw reads, channel
enable/disable, self-calibration, and power-state control.

```
Top-level
   +-- Adc_EnableChannel   channel = {ADC_channel}          -- (de)activate a channel
   +-- Adc_ReadRawData     channel = {ADC_channel}          -- raw single-channel read
   +-- Adc_Calibrate       hw_unit = AdcHwUnit_0            -- self-calibration pass
   +-- Adc_SetPowerState   power_state = ADC_LOW_POWER       -- driver to low-power
```

---

## 7. Interrupt Dependencies

1. **Interrupt / CTU modes:** one `Hardware_Interrupt_Handler` **per
   notification** consumed. A two-group interrupt model has two (one per
   group-end notification); a CTU model has one per CTU / FIFO
   notification.
2. **Polling mode:** no ISR handler in the model.
3. **`irqHandlers.Enum` under `irqGroup = Adc` enumerates all declared
   group-end notifications plus CTU / FIFO notifications** (INV-3). The
   exact notification strings are derived by the config tool from the
   application-chosen group names and the HW unit -- **read the live
   `irqHandlers.Enum`, never assume**. The set includes per-group
   end-of-conversion notifications, watchdog notifications, CTU
   new-data / list-last / overrun notifications, and FIFO
   watermark / overrun / underrun notifications. The set grows with each
   group / CTU / FIFO you give a notification in the config tool.
4. NVIC enablement: enable the ADC hardware unit (and BCTU, for CTU mode)
   IRQn per unit whose notification is consumed -- verify exact names via
   the `.mex`.

To wire a notification: add a `Hardware_Interrupt_Handler`, set
`irqGroup = Adc`, then set `irqHandlers` to the exact group / CTU / FIFO
notification name from the live enum. ADC notifications **never** route
through a parameter on the `Adc` block (INV-3).

---

## 8. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| HW unit logical name (`AdcHwUnit_0`) | Peripherals -> Adc | `hw_unit.Enum` on `Adc` block |
| Group logical name (application-chosen) + GroupNotification | Peripherals -> Adc | `group.Enum`; notification appears in `irqHandlers.Enum` |
| Group channel list + conversion mode (one-shot / continuous) | Peripherals -> Adc | Compiled-in; not exposed on block |
| Group trigger source (SW / HW / CTU) | Peripherals -> Adc | Picks the matching `api_func` (`Adc_StartGroupConversion` vs `Adc_*HardwareTrigger` vs CTU) |
| Channel logical name (application-chosen) + input mapping | Peripherals -> Adc | `channel.Enum` on `Adc` block |
| Resolution, sampling time, clock divider | Peripherals -> Adc -> HW unit | Compiled-in; not exposed |
| BCTU unit / trigger / FIFO (`BctuHwUnit_0`, `AdcHwTrigger_N`, `BctuResultFifos_N`) | Peripherals -> Adc (CTU) | `ctu_*` enums on `Adc` block |
| Analog watchdog threshold control | Peripherals -> Adc | `threshold_control.Enum` on `Adc` block |
| Clock source (`ADC_CLK`) | Peripherals -> Adc -> clock reference -> Mcu | Compiled-in; not exposed |
| DMA channel assignment (CTU / DMA) | Peripherals -> Mcl | Compiled-in; not exposed |
| Analog input pin muxing | Pins | Compiled-in; not exposed |
| NVIC enable | Platform -> Interrupt Controller | Manifests as the group / CTU / FIFO notification firing |
| Power state target | Simulink model | `power_state` on `Adc_SetPowerState` / `Adc_PreparePowerState` |
| Board-init entry `Adc_Init(&Adc_Config)` | `editing-mbdt-board-init` skill | Emitted into `mbdt_board_init.c` |

### 8.1 Cross-component links inside the `.mex`

The Adc driver does not stand alone: several other driver instances hold
**cross-references** (`value="/.../..."`) that wire the acquisition
together (all owned config-tool-side, visible only via
`nxp_s32ct_inspect(kind='xrefs')`). Read live -- never assume the exact
element names, which include application-chosen group and channel names.

| Link (source -> destination) | Reference path (destination) | Meaning |
|---|---|---|
| Adc (internal) -> conversion group | `/Adc/Adc/AdcConfigSet/{group name}` (application-named, renamable, e.g. `AdcGroup_0`) | The application-chosen conversion group (INV-1) and the source of the block's `group.Enum` (Sec.2.3) |
| Adc (internal) -> HW-unit channel | `/Adc/Adc/AdcConfigSet/AdcHwUnit_N/{channel}` (application-named; PWM-named channels indicate a PWM-driven acquisition) | The ordered channel list bound to each ADC hardware unit (INV-1) |
| Adc (internal) -> BCTU trigger | `/Adc/Adc/AdcConfigSet/AdcHwTrigger_N` | The BCTU trigger index each hardware-triggered group is armed on |
| Adc -> Mcu (clock) | `/Mcu/.../McuClockSettingConfig_0/...` (e.g. `ADC_CLK`) | The ADC clock source is owned by the Mcu clock tree, not the Adc driver |
| Adc -> EcuC (partition / core) | `/EcuC/.../EcucPartitionCollection_0/EcucPartition_N`, `/EcuC/.../EcucCoreDefinition_N` | Which core / OS partition the Adc driver instance is bound to |
| Mcl -> DMA channel (ADC) | `/Mcl/Mcl/MclConfig/{dma-channel}` (application-named, e.g. an ADC-oriented DMA logic channel) | A DMA logic channel dedicated to moving ADC results -- lives in the Mcl driver, picked up by Adc internally (Sec.4.3) |
| Mcl -> eMIOS master bus (CTU example) | `/Mcl/Mcl/MclConfig/EmiosCommon_N/EmiosMclMasterBus_N` | The eMIOS / TRGMUX / LCU routing that arms the BCTU -> ADC hardware trigger chain (Sec.6.2) |

Practical reading of the links: the **Adc<->Mcl DMA link** is the
config-tool evidence behind the DMA-backed mode (Sec.4.3); the
**PWM -> TRGMUX -> LCU -> BCTU -> ADC** trigger chain (Sec.6.2) surfaces in
xrefs as Mcl-owned eMIOS master-bus references plus the Adc-internal
`AdcHwTrigger_N` references, and PWM-named ADC channels confirm the PWM
edge is the acquisition source. None of these links is exposed on the
`Adc` block -- they are all config-tool-owned and visible only via `.mex`
xref inspection.

---

## 9. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `hw_unit` / `group` / `channel` enum = "No ... configured" | Usually a **stale cached enum** on the linked block; only sometimes a genuinely undeclared resource | **First** `open_system({adcBlk})` + `pause(1)` and re-read the enum (Sec.2.4). Only if still missing, open config tool via `opening-mbdt-config-tool` and add it in Peripherals -> Adc |
| `threshold_control` enum = "No ADC threshold control configured" | **Expected** on models that do not use the analog watchdog | Ignore, unless you select a watchdog / threshold `api_func` |
| Build links but no conversions happen | Missing board-init entry `Adc_Init(&Adc_Config)` | Verify `Adc_Init` in board init (Sec.4.5). Never stub it |
| `Adc_ReadGroup` returns stale / zero data | `Adc_SetupResultBuffer` not called for that group (INV-2), or conversion never started | Add `Adc_SetupResultBuffer` in the Initialize Function (Sec.5); ensure `Adc_StartGroupConversion` runs |
| Group-end notification never fires | `Adc_EnableGroupNotification` missing, ISR handler missing, or ADC IRQn disabled (INV-3) | Add `Adc_EnableGroupNotification` at init; add the ISR handler (`irqGroup = Adc`, correct group notification); enable NVIC (Sec.4.4, 7) |
| ISR fires but wrong subsystem runs | `irqHandlers` set to the wrong group's notification | Read `irqHandlers.Enum` live; pick the exact group notification name |
| CTU conversions never produce data | `Adc_EnableCtuControlMode` not called, or BCTU trigger / FIFO not declared in Peripherals -> Adc | Enable CTU control mode at init; declare the BCTU unit / trigger / FIFO; enable the BCTU NVIC entry (Sec.6.2) |
| Build fails: unresolved `Adc_Init` / `Adc_ReadGroup` | Missing board-init entry | Add via `editing-mbdt-board-init`. Never stub the function |
| Build fails: `fatal error: Adc_Cfg.h` / `Adc_Ip_Cfg.h` No such file | Config tool did not emit the ADC config unit | Do NOT edit the model. Run `nxp_s32ct_validate(project_path={.mex}, tool_name="Peripherals")`; read problems; re-generate. See Sec.4.5 |

---

## 10. Board-Specific Considerations

- **Analog input pins vary per board.** Which physical pad backs each
  channel is board-specific -- verify against the model's `.mex` via
  `nxp_s32ct_inspect(kind='pins')`. Never invent pin numbers.
- **Group and channel labels are application-named** (INV-1). The group
  names and channel names are strings chosen in Peripherals -> Adc; the
  user can rename them freely. Read them live; do not assume any fixed
  naming scheme or that a channel maps to any fixed ADC input number.
- **Group-to-HW-unit binding is config-tool-owned** (INV-1). The block
  sees `AdcHwUnit_N` and the application group names; the channel list and
  trigger source behind each group live in the config tool.
- **Cross-family portability.** The behavioral model (the live-discovered
  `api_func` set, the HW-unit -> group -> channel hierarchy,
  INV-1/INV-2/INV-3, per-group end notifications, CTU mode with its BCTU
  enums, ISR routing through the family handler) is expected to hold on. Family-specific differences to discover live:
  - board-init component name (`Adc`) / header (`Adc.h`) -- via
    `get_mbdt_board_init({family})`;

---

## 11. Guardrails (ADC-specific)

- **Never stub ADC functions.** Do not hand-write `Adc_Init`,
  `Adc_SetupResultBuffer`, `Adc_StartGroupConversion`, `Adc_ReadGroup`,
  any `Adc_*Notification`, or any RTD function into generated C. The
  board-init entry (Sec.4.5) is what triggers MBDT to generate the driver
  code.
- **Never invent HW-unit / Group / Channel / BCTU names** (INV-1).
  `AdcHwUnit_0`, `BctuHwUnit_0`, `AdcHwTrigger_0`, `BctuResultFifos_0` are
  exact strings from the config tool; group and channel names are
  application-chosen and vary per project. Read them all from the block's
  live enums.
- **`Adc_SetupResultBuffer` is mandatory before any conversion** (INV-2).
  Without it the driver has no buffer to fill; `Adc_ReadGroup` returns
  undefined data and (in interrupt mode) the notification never fires.
  This is a runtime silence, not a build error.
- **Start conversions and read results against a Group, not a Channel**
  (INV-1). `Adc_StartGroupConversion` / `Adc_ReadGroup` take `group`; the
  `channel` enum is only for the per-channel functions (`Adc_EnableChannel`,
  `Adc_ReadRawData`, ...).
- **Match the trigger `api_func` to the group's configured trigger
  source.** A software-triggered group uses `Adc_StartGroupConversion`; a
  hardware-triggered group uses `Adc_EnableHardwareTrigger`; a
  CTU-triggered group uses the CTU family. Mixing them silently
  misbehaves.
- **Never route an ADC notification through a parameter on the `Adc`
  block** (INV-3). All ADC notifications (group-end, CTU, FIFO) go through
  the `Hardware_Interrupt_Handler` block , and
  `irqHandlers` must be the exact live notification name.
- **Set `api_func` first**, before any resource enum.
- **Never set `text` on any `Adc` block** -- system-managed.
