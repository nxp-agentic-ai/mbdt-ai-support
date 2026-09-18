# ICU -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the ICU (Input
Capture Unit) peripheral on any NXP MBDT-targeted Simulink model. Covers
the `Icu` block (`MaskType = {family}_icu`), ISR-handler wiring, the four
measurement modes (signal edge detect, signal measurement, timestamp,
edge counter), and external-config-tool dependencies. The behavioral
model is expected to hold cross-family
(S32K3); enum labels, HW-channel
identifiers, and board-init symbols may differ per family.

ICU has **no data path on the wire** -- the input is a plain digital
line captured by SIUL2 (GPIO external interrupt) or an eMIOS channel
(timer capture). All output is metadata (duty, period, edge count,
timestamps) delivered via polling reads or callbacks. **SIUL2 backs
edge-detect / edge-counter on GPIO EIRQ lines; eMIOS is required for
`ICU_MODE_SIGNAL_MEASUREMENT` and `ICU_MODE_TIMESTAMP`.**

> **Tip -- start from a shipped example.** ICU examples shipped with the
> family MBDT toolbox already form a coherent end-to-end setup (S32CT
> Pins / Peripherals->Icu / Peripherals->Mcl / Interrupt Controller +
> Simulink board init, initialize function, callback subsystem, ISR
> wiring) that mirrors every section below. Open via the
> [`opening-mbdt-example`](../../../opening-mbdt-example/SKILL.md) skill;
> discover names at runtime, never from memory.

---

## 1. Peripheral Overview

Adding "ICU to a model" means placing four artefacts, not one block:

| # | Artefact | Where | Owner |
|---|---|---|---|
| 1 | S32CT / EB tresos project (Pins, Peripherals->Icu, Peripherals->Mcl when eMIOS master bus is used, Interrupt Controller per HW channel) | External | External config tool |
| 2 | Board-init entry `Icu_Init(&Icu_Config)` | `mbdt_board_init.c` | `editing-mbdt-board-init` skill |
| 3 | Initialize Function priming (`Icu_EnableNotification` + mode-specific arm) | Simulink model | This skill |
| 4 | Runtime blocks (`Icu_Get*` reads + `Hardware_Interrupt_Handler` + callback subsystem) | Simulink model | This skill |

Failure modes: missing (1) -> sentinel enums or missing NVIC entries;
missing (2) -> `Icu_*` calls are no-ops; missing (3) -> hardware
initialized but disarmed; missing (4) -> events never observed.

---

## 2. The `Icu` Block -- Complete Behavioral Model

**One `Icu` block = one `Icu_*` function call.** `MaskType =
{family}_icu` (e.g. `s32k3_icu`). An ICU peripheral in a model is
composed of several `Icu` blocks with different `api_func` values.

### 2.1 The `api_func` enum -- the function selector

**Always read the live `api_func.Enum`** via `get_param({icuBlk},
'DialogParameters')` -- the function set is owned by the installed
toolbox version and must never be carried from memory. Names below are
**illustrative** (from S32K3 examples); validate before selection and
refuse near-misses.

ICU is **mode-driven** -- valid `api_func` values depend on the
channel's `IcuMeasurementMode` (set in the config tool, not on the
block):

| `IcuMeasurementMode` | Arm / disarm | Readout / control |
|---|---|---|
| `ICU_MODE_SIGNAL_EDGE_DETECT` | `Icu_EnableEdgeDetection` / `Icu_DisableEdgeDetection` | `Icu_GetInputState` |
| `ICU_MODE_SIGNAL_MEASUREMENT` | `Icu_StartSignalMeasurement` / `Icu_StopSignalMeasurement` | `Icu_GetDutyCycleValues`, `Icu_GetTimeElapsed` |
| `ICU_MODE_TIMESTAMP` | `Icu_StartTimestamp` (buffer via ports) / `Icu_StopTimestamp` | `Icu_GetTimestampIndex` |
| `ICU_MODE_EDGE_COUNTER` | `Icu_EnableEdgeCount` / `Icu_DisableEdgeCount` | `Icu_GetEdgeNumbers`, `Icu_ResetEdgeCount` |

Mode-independent functions:

- `Icu_EnableNotification` / `Icu_DisableNotification` -- gate whether
  the configured `Icu*Notification` fires. **Notification arming is
  separate from mode arming**; the shipped Initialize Function calls
  **both** (see Sec.5).
- `Icu_SetActivationCondition` -- change active edge polarity at run
  time (`ICU_RISING_EDGE` / `ICU_FALLING_EDGE` / `ICU_BOTH_EDGES`);
  initial value is `IcuDefaultStartEdge` in the config tool.
- `Icu_SetMode` -- `ICU_MODE_SLEEP` / `ICU_MODE_NORMAL` power control
  (not measurement-mode switching).
- `Icu_EnableWakeup` / `Icu_DisableWakeup` / `Icu_CheckWakeup` -- use
  the `source` parameter; only for channels with
  `IcuWakeupCapability = true`.
- `Icu_GetVersionInfo` -- no channel; writes module/vendor IDs to a
  Data Store.

Selecting `api_func` reshapes the S-Function's ports and toggles
visibility of every other parameter. **Set `api_func` first.**

### 2.2 Parameter surface

Parameter *names* are identical on every `Icu` block; only visibility
and semantics change with `api_func`.

| Name | Type | Semantics | Meaningful for |
|---|---|---|---|
| `api_func` | enum | Function selector | All |
| `channel` | enum | `IcuChannel_N` -- logical driver channel | All except `Icu_GetVersionInfo` |
| `source` | enum | Wakeup source index (integer as string) | Wakeup functions only |
| `text` | string | System-managed cache -- **never set** | Read-only |

### 2.3 The `channel` and `source` enums

**Read `channel.Enum` and `source.Enum` live** via `get_param`; never
enumerate from memory. `channel` values follow `IcuChannel_0 | ... |
IcuChannel_N`. The **logical driver channel is not the physical HW
channel** -- the mapping is:

```
IcuChannel_{N}  ->  IcuChannelId = N  ->  IcuChannelRef  ->  SIUL2 pin OR eMIOS channel
```

`IcuChannelRef` lives in Peripherals->Icu; discover via
`nxp_s32ct_inspect(kind='instances')` or the EB tresos Icu module.

**Sentinels.** If the config tool is empty, `channel` collapses to
`"No channels configured"` and `source` to `"0"` only. A sentinel is
never a valid selection: a real `channel` value must be selected for
every `api_func` **except** `Icu_GetVersionInfo` (which requires no
channel). Sentinels are often
stale after a `.mex` edit -- run `open_system({icuBlk})` then
`pause(1)` to force mask re-enumeration.

### 2.4 Selection ordering

1. `api_func` first (reshapes ports/visibility).
2. `channel` next (except `Icu_GetVersionInfo`).
3. `source` last (wakeup functions only).

---

## 3. Required Block Catalog

| Block | `MaskType` | Role |
|---|---|---|
| `Icu` (one per `Icu_*` call) | `{family}_icu` | Single-function ICU S-Function |
| `Hardware_Interrupt_Handler` | `{family}_isr_handler` | Routes signal / overflow / timestamp callback into a function-call subsystem |
| Callback subsystem (function-call) | Simulink `SubSystem` | User logic per notification |
| `Data Store Memory` (optional) | Simulink builtin | Version-info readback, edge counters, timestamp buffer sharing |



---

## 4. Configuration Workflow (6 steps)

### 4.1 Pins (config tool)

Route the input to a legal **SIUL2 EIRQ pin** (edge-detect / edge-count)
or a legal **eMIOS channel input pin** (signal measurement / timestamp,
alt-mode `EMIOS_{M}_CH_{C}`).

### 4.2 Peripherals -> Icu (config tool)

Per channel:

- `IcuChannelId` -- fixes the `IcuChannel_{N}` label on the block.
- `IcuChannelRef` -- SIUL2 (`.../IcuSiul2_{M}/IcuSiul2Channels_{K}`) or
  eMIOS (`.../IcueMios_{M}/IcueMiosChannels_{K}`) entry.
- `IcuMeasurementMode`, `IcuDefaultStartEdge`.
- Mode-specific sub-container: `IcuSignalEdgeDetection/IcuSignalNotification`;
  or `IcuSignalMeasurement/IcuSignalMeasurementProperty` (`ICU_DUTY_CYCLE` |
  `ICU_PERIOD_TIME` | `ICU_HIGH_TIME` | `ICU_LOW_TIME`);
  or `IcuTimestampMeasurement/IcuTimestampMeasurementProperty`
  (`ICU_CIRCULAR_BUFFER` | `ICU_LINEAR_BUFFER`) plus
  `IcuTimestampNotification`; edge-counter uses `IcuOverflowNotification`
  only.
- `IcuOverflowNotification` -- callback name or `NULL_PTR`.
- `IcuDMAChannelEnable` -- `true` requires a matching Mcl DMA channel.
- `IcuWakeupCapability` + wakeup source configuration.

eMIOS-backed channels also need `IcueMios_{M}` (`IcueMiosModule`, per-
channel `IcuEmiosBusSelect`, `IcuEmiosBusRef`, `IcuEmiosPrescaler`,
`IcuSubModeforMeasurement`, digital filter).

### 4.3 Peripherals -> Mcl (config tool, eMIOS channels only)

`IcuEmiosBusSelect` decides whether Mcl is involved:

- `EMIOS_ICU_BUS_INTERNAL_COUNTER` -- channel uses its own counter;
  `IcuEmiosBusRef` empty; no Mcl configuration required.
- `EMIOS_ICU_BUS_DIVERSE` (and family variants `_A` / `_B` / `_C` /
  `_D` / `_F`) -- channel reads a shared timer counter owned by Mcl;
  `IcuEmiosBusRef` **must** point at an existing
  `/Mcl/Mcl/MclConfig/EmiosCommon_{M}/EmiosMclMasterBus_{K}` or S32CT
  `-ShowProblems` reports the xref unresolved and codegen fails.

A single `EmiosMclMasterBus_{K}` is normally shared by every downstream
channel on the module -- Mcl owns the timebase, ICU owns the capture
logic on top.

**Prescaler math -- two dividers in series:**
`f_emios_tick = f_emios_module / (Mcl master-bus prescaler) /
(IcuEmiosPrescaler)`. Duty / period / timestamp math must account for
both, not just one.

### 4.4 Interrupt Controller (config tool)

One `IcuHwInterruptConfigList_{K}` entry per active HW channel with
`IcuIsrHwId` = `SIUL2_{M}_IRQ_CH_{pinIdx}` (GPIO) or `EMIOS_{M}_CH_{C}`
(eMIOS). Missing / wrong `IcuIsrHwId` -> callback never runs.

### 4.5 Board initialization (Simulink model)

```
Component : Icu             <- as returned by get_mbdt_board_init
Priority  : 110             <- priority relative to sibling components
Enabled   : true
Header    : #include "Icu.h"
Code      : Icu_Init(&Icu_Config);
```

Use the [`editing-mbdt-board-init`](../../../editing-mbdt-board-init/SKILL.md)
skill; never hand-write the init.

#### RTD documentation (Integration + User Manual)

Read the **UM** and the **IM** before you modify the external
configuration tools project (S32CT / EB tresos), or before you implement
a user request the shipped examples do not cover. The **UM** tells you
how each `api_func` behaves, so you pick and drive the right function;
the **IM** covers generated-file expectations, init order, and NVIC
prerequisites. `{family_root}` = `mbd_find_{family}_root()`; glob RTD-
version segments (filenames are uppercased):


```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Icu_TS_T40D*_M70I*_R0\doc\
    RTD_ICU_IM.pdf   RTD_ICU_UM.pdf
```

For eMIOS-backed channels, the **Mcl** master-bus configuration
(`EmiosMclMasterBus_{K}`, master-bus prescaler feeding `IcuEmiosBusRef`)
is documented in the Mcl PDFs:

```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Mcl_TS_T40D*_M70I*_R0\doc\
    RTD_MCL_IM.pdf   RTD_MCL_UM.pdf
```

### 4.6 Initialize Function and callback subsystem

See Sec.5 and Sec.6.

---

## 5. Initialize Function

Place one `Icu` block per priming call inside `Initialize Function`, in
order:

| `IcuMeasurementMode` | Priming calls (in order) |
|---|---|
| `ICU_MODE_SIGNAL_EDGE_DETECT` | `Icu_EnableNotification`, `Icu_EnableEdgeDetection` |
| `ICU_MODE_SIGNAL_MEASUREMENT` | `Icu_EnableNotification`, `Icu_StartSignalMeasurement` |
| `ICU_MODE_TIMESTAMP` | `Icu_EnableNotification`, `Icu_StartTimestamp` (buffer address + length on ports) |
| `ICU_MODE_EDGE_COUNTER` | `Icu_EnableNotification` (if overflow notification used), `Icu_EnableEdgeCount` |

An `Icu_GetVersionInfo` block writing to a Data Store may also live
here for diagnostic readback.

---

## 6. Runtime Data Flow

The interrupt-driven path is identical for all four modes; only the
notification symbol and the readout functions differ:

```
[external pin] --edge--> SIUL2 IRQ or eMIOS capture --> Icu ISR --> Icu*Notification
                                                                          |
                                                                          v
                                                             Hardware_Interrupt_Handler
                                                             (irqGroup=Icu,
                                                              irqHandlers={callback})
                                                                          |
                                                                          v
                                                              function-call subsystem
```

- **Edge-detect** -- `IcuSignalNotification` fires per edge; no polling
  read strictly required (`Icu_GetInputState` polls edge-since-read).
- **Signal measurement** -- polling: read `Icu_GetDutyCycleValues` or
  `Icu_GetTimeElapsed` from a periodic subsystem;
  `IcuOverflowNotification` fires on counter overflow.
- **Timestamp** -- ports pass destination buffer address + length to
  `Icu_StartTimestamp`; driver writes one entry per edge;
  `IcuTimestampNotification` fires per fill or per wrap (linear vs
  circular); drain via `Icu_GetTimestampIndex`.
- **Edge counter** -- read count via `Icu_GetEdgeNumbers`; reset via
  `Icu_ResetEdgeCount`; `IcuOverflowNotification` on rollover.

---

## 7. Interrupt Dependencies

ICU always uses **one HW interrupt per active channel, even in polling
modes** -- the driver relies on the ISR to advance internal state
(counter overflow accumulation, timestamp buffer fills, edge-count
rollovers). Signal-measurement and edge-counter channels therefore
still require an `IcuHwInterruptConfigList_{K}` entry with a valid
`IcuIsrHwId` and typically wire `IcuOverflowNotification`. Skipping the
NVIC entry on a polling channel silently corrupts every `Icu_Get*` read
after the first counter wrap.

Dispatch to the model:

- **HW-channel IRQ identifier** -> `IcuIsrHwId` under
  `IcuHwInterruptConfigList_{K}`.
- **Notification symbol** (`IcuSignalNotification`,
  `IcuOverflowNotification`, `IcuTimestampNotification`) is declared in
  the config tool and dispatched via `Hardware_Interrupt_Handler` with
  `irqGroup = Icu`, `irqHandlers = {exact symbol}`, `irqSim = off`
  (unless simulated).

**One `Hardware_Interrupt_Handler` per distinct notification symbol.**
N different `Icu*Notification` symbols -> N separate handler blocks at
model root, same `irqGroup = Icu`, distinct `irqHandlers`, each feeding
its own function-call subsystem.

Any of: missing NVIC entry, wrong `IcuIsrHwId`, typo between the
config-tool symbol and `irqHandlers` -> callback never runs.

---

## 8. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| `IcuChannelId` / `IcuChannel_{N}` label | Config tool | `channel` enum |
| `IcuChannelRef` (SIUL2 pin / eMIOS channel) | Config tool | Not visible; use `nxp_s32ct_inspect` |
| `IcuMeasurementMode` | Config tool | Drives which `api_func` values are valid |
| `IcuDefaultStartEdge` | Config tool | Overridden at runtime by `Icu_SetActivationCondition` |
| `Icu*Notification` symbols | Config tool | Must match `Hardware_Interrupt_Handler.irqHandlers` |
| `IcuIsrHwId` | Config tool NVIC | Drives whether notification fires |
| `IcuWakeupCapability` + wakeup source index | Config tool | `source` enum on wakeup `api_func` values |
| `IcuDMAChannelEnable` | Config tool | Requires matching Mcl DMA channel |
| `IcuEmiosBusRef` | Config tool | Requires matching Mcl `EmiosMclMasterBus_{K}` |

**Runtime observability:** `Icu_GetInputState`, `Icu_GetDutyCycleValues`
(`{ActivePulseWidth, Period}`), `Icu_GetTimeElapsed`,
`Icu_GetEdgeNumbers`, `Icu_GetTimestampIndex`, `Icu_GetVersionInfo`.

---

## 9. Common Usage Patterns

- **GPIO button -> edge callback.** SIUL2 pin +
  `ICU_MODE_SIGNAL_EDGE_DETECT` + `IcuSignalNotification`; NVIC
  `SIUL2_{M}_IRQ_CH_{pin}`; model primes
  `Icu_EnableNotification` + `Icu_EnableEdgeDetection`; callback toggles
  a Dio pin or updates a state.
- **PWM input -> duty / period.** eMIOS channel + Mcl master bus +
  `ICU_MODE_SIGNAL_MEASUREMENT` + `ICU_DUTY_CYCLE`;
  `IcuOverflowNotification`; NVIC `EMIOS_{M}_CH_{C}`; periodic subsystem
  reads `Icu_GetDutyCycleValues`.
- **Edge timestamps -> circular buffer.** eMIOS +
  `ICU_MODE_TIMESTAMP` + `ICU_CIRCULAR_BUFFER` +
  `IcuTimestampNotification`; Data Store sized to buffer; address +
  length into `Icu_StartTimestamp`; drain via `Icu_GetTimestampIndex`
  in the callback.
- **Pulse counter.** eMIOS + `ICU_MODE_EDGE_COUNTER`;
  `IcuOverflowNotification` optional; periodic `Icu_GetEdgeNumbers` +
  `Icu_ResetEdgeCount` per rollover policy.

---

## 10. Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `channel` enum only shows sentinel | No ICU channel declared in the external configuration tool (S32CT / EB tresos) -- Peripherals->Icu is empty | Add an `IcuChannel_{N}` in the external configuration tool (S32CT / EB tresos), then re-open the block (`open_system({icuBlk})` + `pause(1)`) to force the mask to re-read the channel list |
| Build OK, callback never fires | NVIC missing or `IcuIsrHwId` mismatches pin/channel | Add / correct `IcuHwInterruptConfigList_{K}.IcuIsrHwId` |
| Correct NVIC but subsystem never executes | `Icu_EnableNotification` not called | Add before the mode-specific arming call |
| `Icu_GetDutyCycleValues` always zero | `Icu_StartSignalMeasurement` not called | Add priming call |
| `IcuEmiosBusRef` unresolved at code-gen | `EmiosMclMasterBus_{K}` absent in Mcl | Add master bus or repoint |
| Wakeup `api_func` ignores channel | `IcuWakeupCapability = false` or no source declared | Enable in config tool; verify `source` enum |
| Edge polarity wrong after runtime change | `Icu_SetActivationCondition` used with polarity unsupported by current mode | Consult RTD ICU UM; use allowed polarity |
| Notification fires but reads stale | Config-tool symbol != `irqHandlers` string | Align exactly |
| Polling-mode reads corrupt after first wrap | NVIC entry skipped on polling channel | ICU always needs the ISR (Sec.7) |

---

## 11. Board-Specific Considerations

- **Backend selection is board-driven** -- the input signal must
  physically land on a pin whose alt function reaches the chosen SIUL2
  EIRQ line or eMIOS channel. Discover legal pins with
  `nxp_s32ct_inspect(kind='pin_signal', signal='{sig}')`.
- **eMIOS master bus.** Verify `EmiosMclMasterBus_{K}` exists in Mcl
  before setting `IcuEmiosBusSelect = EMIOS_ICU_BUS_DIVERSE` (Sec.4.3).
- **Digital filter.** `IcuEmiosDigitalFilter` and
  `IcuSiul2Channels_{K}/Icu_EXT_ISR_IFMCDigitalFilter` can silently
  suppress fast edges -- start with the filter bypassed during bring-up.
- **Cross-family portability.** Behavioral model holds; exact board-
  init component name/header, measurement-mode enum labels, and
  HW-channel identifier grammar may differ. Confirm with
  `get_mbdt_board_init({family})` and the family's shipped ICU
  examples.

---

## 12. Guardrails (icu-specific -- supersedes nothing in parent SKILL.md)

1. **Never stub RTD functions.** Missing `Icu_Init` / `Icu_*` symbols
   always mean a config-tool or board-init gap (Sec.4.5), never a
   request to author driver code by hand.
2. **Never invent channel names.** `IcuChannel_{N}` values are owned by
   the config tool -- read live via `get_param`; never enumerate from
   memory; never infer the physical HW channel from the label
   (consult `IcuChannelRef`).
3. **Never invent HW-channel IDs.** `IcuIsrHwId` values
   (`SIUL2_{M}_IRQ_CH_{N}`, `EMIOS_{M}_CH_{C}`, family variants) are
   owned by the config-tool NVIC UI.
4. **Never set `text` on any `Icu` block.** System-managed.
5. **Never route the callback through a parameter on the `Icu` block.**
   Callbacks flow through `Hardware_Interrupt_Handler` with `irqGroup = Icu` and `irqHandlers` matching the
   config-tool notification symbol.
6. **Set `api_func` first** (reshapes ports + visibility).
7. **Always pair `Icu_EnableNotification` with the mode-specific
   arming call** in Initialize Function -- enabling only one is a
   silent-init failure neither the build nor the linker catches.
8. **`api_func` must be consistent with `IcuMeasurementMode`** -- e.g.
   `Icu_StartSignalMeasurement` on an `ICU_MODE_EDGE_COUNTER` channel
   is a runtime error; validate mode-vs-function before selection.
