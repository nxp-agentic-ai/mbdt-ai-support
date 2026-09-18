# GPT -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the GPT (General
Purpose Timer) peripheral on any NXP MBDT-targeted Simulink model. Covers
the `Gpt` block (`MaskType = {family}_gpt`), the channel-based timer
runtime pattern, the per-channel timer-expiry notification ISR wiring,
and the external-config-tool dependencies. The behavioral model is
expected to hold cross-family (S32K3); exact
enum labels and board-init symbols may differ per family and are verified
only on S32K3 (RTD, MATLAB R2026a). Sections run in order: *what GPT is*
-> *block model* -> *config tool* -> *board init* -> *init start* ->
*runtime reads* -> *interrupts*, then correlation matrix, troubleshooting,
and guardrails.

## The three GPT invariants (referenced throughout)

Three facts govern every GPT decision below. They are stated once here
and referenced by name; later sections do not re-derive them.

- **INV-1 -- GPT is an abstraction layer over a lower timer IP.** A
  `Gpt` channel is not a raw hardware timer; it is a logical channel
  bound to a **backing timer IP instance** -- PIT (Periodic Interrupt
  Timer), STM (System Timer Module), or another counter -- chosen inside
  the config project. The block exposes only the logical channel name;
  which timer IP backs it, its IP channel index, its one-shot/continuous
  mode, its default target, and its timer clock are all
  **config-tool-owned** and surface only in the `.mex` (see the canonical
  tree in Sec.2.3). Everything derived from the backing IP -- the
  notification callback string, the generated IP config file -- must be
  **read live, never assumed**. On S32K3 every shipped GPT example
  (S32CT and EB tresos alike) is **PIT-backed**
  (`GptPit_0/GptPitChannels_M`, notification `Gpt_PitNotification`); STM
  (`GptStm_*`, `Gpt_StmNotification`) is schema-supported but unused by
  any shipped example.

- **INV-2 -- Two named channels are mandatory in every MBDT GPT model.**
  Beyond any application timers, the `channel` enum always contains
  `StepTimer` (backs the model's base-rate step scheduling) and
  `ProfilerTimer` (backs the MBDT execution profiler). They are
  toolbox-provisioned and started by the toolbox infrastructure, not by
  user blocks. **Never remove them** -- deleting either silently breaks
  base-rate timing or profiling. A GPT model that lacks them is
  misconfigured. Application channel names (`GptChannelConfiguration_N`
  or any application-chosen string) vary per project and must be read
  live; `StepTimer` / `ProfilerTimer` are the fixed exceptions.

- **INV-3 -- A configured channel must be started.** `Gpt_StartTimer` is
  the mandatory init action for any channel the application actively uses
  (there is no result-buffer call as in ADC). Without it the channel is
  configured but frozen: `Gpt_GetTimeElapsed` returns a stale value and
  no notification fires. This is a runtime silence, not a build error.

> **Tip -- start from a shipped example.** Open a shipped GPT example via
> [`opening-mbdt-example`](../../../opening-mbdt-example/SKILL.md); its
> `.mex` project (Peripherals -> Gpt with channels declared under a
> lower-timer-IP node, Peripherals -> Mcu for the timer clock,
> Platform -> NVIC) plus its model (board init, Initialize Function with
> `Gpt_StartTimer` + optional `Gpt_EnableNotification`, top-level
> `Gpt_GetTimeElapsed` / `Gpt_GetTimeRemaining`, optional expiry ISR
> handler) forms a coherent end-to-end reference that mirrors the
> sections below. Always confirm behavior against a current model via
> live discovery (`get_mbdt_toolbox(family, 'examples')`,
> `get_param(..., 'DialogParameters')`, `nxp_s32ct_inspect`) -- never
> carry example names, channel names, or callback strings from memory.

---

## 1. Peripheral Overview

Adding "GPT to a model" means placing several artefacts, not one block:

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT / EB tresos project (Peripherals -> Gpt with each channel declared under a lower-timer-IP node such as `GptPit_0`; Peripherals -> Mcu for the timer clock; Platform -> NVIC) | External to the model | External config tool |
| 2 | Board-init entry `Gpt_Init(&Gpt_Config)` | `mbdt_board_init.c`, emitted at code-gen | `editing-mbdt-board-init` skill |
| 3 | Initialize Function blocks: `Gpt_StartTimer` + (interrupt mode) `Gpt_EnableNotification` | Simulink model | This skill |
| 4 | Runtime blocks: `Gpt_GetTimeElapsed` / `Gpt_GetTimeRemaining` + (interrupt mode) `Hardware_Interrupt_Handler` routing a `Gpt_{IP}Notification` | Simulink model | This skill |

**Silent failure modes if any is missing:**

- Missing (1) -> block enums resolve to `"No ... configured"` sentinels
  on `channel`; the timer has no backing IP channel.
- Missing (2) -> build links but every `Gpt_*` call is a no-op; the timer
  never runs.
- Missing (3) -> INV-3: the channel is configured but never counts.
- Missing (4) -> the timer runs but the application never reads elapsed /
  remaining time and never reacts to expiry.

**How GPT differs from other peripherals:** it is an abstraction over a
lower timer IP (INV-1); it is **channel-based**, not group-based -- a
timer is driven per **channel**, the single resource handle for
start/stop, elapsed/remaining reads, mode, wakeup, and notification (no
HW-unit -> group -> channel hierarchy as in ADC); it carries two
mandatory named channels (INV-2); it has **no result buffer** (INV-3);
and its notification is a per-channel timer-expiry callback derived from
the backing IP (INV-1).

---

## 2. The `Gpt` Block -- Complete Behavioral Model

**One `Gpt` block = one `Gpt_*` function call.** Every block has
`MaskType = {family}_gpt` (e.g. `s32k3_gpt`) and is an `S-Function`. A
GPT peripheral in a model is composed of *several* `Gpt` blocks with
different `api_func` values.

### 2.1 The `api_func` enum -- the function selector

**Always read the live `api_func.Enum`** via
`get_param({gptBlk}, 'DialogParameters')` -- the set of available
`Gpt_*` functions is owned by the installed toolbox version and must
never be carried from memory. Whenever this reference names a specific
`Gpt_*` function, treat it as an **illustrative** label observed in the
shipped S32K3 examples; validate it against the block's live
`api_func.Enum` before selecting, and refuse near-misses.

Observed live entries on S32K3 (illustrative):

```
Gpt_CheckWakeup          Gpt_DisableNotification   Gpt_DisableWakeup
Gpt_EnableNotification   Gpt_EnableWakeup          Gpt_GetPredefTimerValue
Gpt_GetTimeElapsed       Gpt_GetTimeRemaining      Gpt_GetVersionInfo
Gpt_SetMode              Gpt_StartTimer            Gpt_StopTimer
```

**Behavioral facts (independent of the exact function list):**

- **`Gpt_StartTimer`** starts a channel counting toward a target value
  (the `value` (ticks) parameter). One-shot vs continuous is set per
  channel in the config tool. Mandatory init action (INV-3).
- **`Gpt_StopTimer`** stops a running channel.
- **`Gpt_GetTimeElapsed` / `Gpt_GetTimeRemaining`** read a channel's
  current count (ticks elapsed since start / ticks left until target).
  The most common runtime reads.
- **`Gpt_EnableNotification` / `Gpt_DisableNotification`** arm / disarm a
  channel's timer-expiry notification. Call `Gpt_EnableNotification` at
  init for interrupt-driven designs.
- **`Gpt_SetMode`** switches the driver between `Normal` and `Sleep`
  operating modes (power management).
- **`Gpt_EnableWakeup` / `Gpt_DisableWakeup` / `Gpt_CheckWakeup`** manage
  a channel's ability to wake the MCU from a low-power state; the
  `source` (Wakeup Source Id) parameter selects the EcuM wakeup source.
- **`Gpt_GetPredefTimerValue`** reads a predefined free-running timer
  (`timer` enum: `GPT_PREDEF_TIMER_1US_16BIT` / `_1US_24BIT` /
  `_1US_32BIT` / `_100US_32BIT`) -- a fixed-resolution time base
  independent of the configured channels.
- **`Gpt_GetVersionInfo`** is diagnostic; needs no resource enum.
- Selecting `api_func` reshapes the S-Function's ports and toggles the
  visibility of every other parameter. **Set `api_func` first.**

### 2.2 Parameter surface (constant across all `api_func` values)

| Name | Type | Prompt | Semantics | Meaningful for |
|---|---|---|---|---|
| `api_func` | enum | Function | Function selector (see Sec.2.1) | All |
| `channel` | enum | Channel | the logical GPT channel handle (incl. mandatory `StepTimer` / `ProfilerTimer`) | Channel-scoped functions (start/stop/elapsed/remaining/notification/wakeup/mode) |
| `value` | string | Value (ticks) | target tick count for `Gpt_StartTimer` | `Gpt_StartTimer` |
| `mode` | enum | Mode | `Normal` \| `Sleep` | `Gpt_SetMode` |
| `source` | enum | Wakeup Source Id | EcuM wakeup source index (`0` \| `1` ...) | `Gpt_*Wakeup` |
| `timer` | enum | Predef Timer | `GPT_PREDEF_TIMER_1US_16BIT` \| `_1US_24BIT` \| `_1US_32BIT` \| `_100US_32BIT` | `Gpt_GetPredefTimerValue` |
| `timer_value_input` | boolean | Timer value as input | route the start value from an input port instead of the `value` field | `Gpt_StartTimer` |
| `text` | string | *(empty)* | System-managed cache -- **never set** | Read-only |

The parameter set is constant across `api_func`; the mask shows/enables
only those meaningful for the selected function. Read live which are
enabled after setting `api_func`.

### 2.3 The resource enums and the canonical `.mex` layout

Observed live `channel` entries on S32K3 (illustrative -- read live;
application channel names differ per project, but `StepTimer` and
`ProfilerTimer` are always present per INV-2):

```
channel : GptChannelConfiguration_0 | GptChannelConfiguration_1 | ProfilerTimer | StepTimer
mode    : Normal | Sleep
source  : 0 | 1
timer   : GPT_PREDEF_TIMER_1US_16BIT | GPT_PREDEF_TIMER_1US_24BIT
        | GPT_PREDEF_TIMER_1US_32BIT | GPT_PREDEF_TIMER_100US_32BIT
```

Semantics:

```
GptChannelConfiguration_N -> a logical GPT channel (application-named in
                             the config tool); the single handle for
                             start / stop / elapsed / remaining /
                             notification / wakeup. NOT a fixed string.
StepTimer / ProfilerTimer -> the two mandatory toolbox channels (INV-2)
GPT_PREDEF_TIMER_*        -> a fixed-resolution free-running predefined
                             time base (independent of the channels)
```

**Canonical `.mex` layout (the single source rendering; all later
sections back-reference this).** The channel names are NOT stored on the
model and NOT fixed by the driver -- they are declared in the config-tool
project's Gpt config tree, nested under the backing timer-IP node, and
must be read from there (INV-1). Confirmed live on S32K3:

```
/Gpt/Gpt/GptChannelConfigSet/         <- the Gpt driver channel config set
    GptPit_0 | GptStm_0 | ...          <- one node per backing timer IP
                                          instance (PIT / STM / ...)
        GptPitChannels_M               <- the backing-IP channels declared
                                          on that instance
                                          (e.g. GptPit_0/GptPitChannels_0)
/Gpt/Gpt/GptDriverConfiguration/
    GptClockReferencePoint_0           <- the timer clock reference (-> Mcu)
```

This is the **timer-IP abstraction relation** (INV-1): a
`GptChannelConfiguration_N` / `StepTimer` / `ProfilerTimer` handle on the
block maps to a `GptPitChannels_M` (or `GptStmChannels_M`) under a
`GptPit_0` / `GptStm_0` node. To read the live names for a project:

- `nxp_s32ct_inspect(kind='instances')` -- locate the `type_id = Gpt`
  instance.
- `nxp_s32ct_inspect(kind='xrefs', root_filter='Gpt')` -- surfaces the
  `/Gpt/Gpt/GptChannelConfigSet/GptPit_0/GptPitChannels_M` and
  `GptClockReferencePoint_0` element paths.

The `mode` / `source` / `timer` enums are fixed driver enumerations; only
`channel` is project-dependent.

### 2.4 Sentinel rules

| `api_func` | resource sentinel = error? |
|---|---|
| `Gpt_GetVersionInfo` | NO -- no resource needed |
| `Gpt_GetPredefTimerValue` | NO -- uses the `timer` enum, not `channel` |
| `Gpt_SetMode` | NO channel -- uses the `mode` enum |
| Everything else | YES (on the `channel` enum it uses) |

> **Open the block first -- the sentinel is often just stale.** The `Gpt`
> block is a **linked** library block; its resource enums are populated
> by a mask initialization callback that fires when the block dialog is
> *opened*. Reading an enum on a freshly loaded model can therefore
> return a cached `"No ... configured"` sentinel even when the config
> tool *has* declared the channel. When you hit a sentinel: first
> `open_system({gptBlk})` + a short `pause(1)`, re-read the enum, and only
> if the resource is still absent route to `opening-mbdt-config-tool` to
> declare the channel in Peripherals -> Gpt under a backing timer-IP node.

### 2.5 Selection ordering

1. `api_func` first -- reshapes ports and toggles visibility.
2. `channel` (the primary resource handle) for channel-scoped functions;
   `timer` for `Gpt_GetPredefTimerValue`; `mode` for `Gpt_SetMode`.
3. `value` / `timer_value_input` for `Gpt_StartTimer`; `source` for
   wakeup functions.

One `set_param` per parameter. Setting a resource enum before `api_func`
leaves it on a stale hidden slot and the model is incoherent.

---

## 3. Required Block Catalog

| Block name | `MaskType` | Role |
|---|---|---|
| `Gpt` | `{family}_gpt` | Wraps one `Gpt_*` function; multiple instances per model |
| `Hardware_Interrupt_Handler` | `{family}_isr_handler` | Routes a timer-expiry notification into a function-call subsystem (interrupt mode) |
| `FreeMASTER Config` (optional) | `{family}_fm_config` | Plots / tunes elapsed time over serial -- **not** a `Gpt` block |

Discover exact paths via `detect_mbdt_blocks({family})`. An
interrupt-driven model places **one** ISR-handler block per timer
notification in use.

---

## 4. Configuration Workflow (config tool)

Steps 4.1-4.4 happen in the external configuration tool; board init
(Sec.4.5) and the model runtime blocks (Sec.5, Sec.6) follow.

### 4.1 Pins

GPT is an internal timer -- it drives **no output pin** by itself, so no
pin routing is required for a plain elapsed/remaining/notification
design. (If a channel is later coupled to an output-capable IP, that pin
lives with that IP, not with Gpt.)

### 4.2 Peripherals -> Gpt (declare the channels)

Under each backing timer-IP node (per the canonical `.mex` tree in
Sec.2.3), assign:

- the backing timer-IP instance (`GptPit_0` / `GptStm_0` / ...);
- the backing-IP channel (`GptPitChannels_M`) with its mode
  (one-shot / continuous), default target, and optional channel
  notification;
- the logical channel handle exposed to the block (incl. `StepTimer` /
  `ProfilerTimer`).

The **exact string names** you assign here are what appear in the block's
`channel` enum -- case-sensitive, 1:1. `type_id = Gpt` (from
`nxp_s32ct_inspect(kind='instances')`); the shipped examples run the Gpt
driver in `autosar` mode. **Do not delete `StepTimer` or `ProfilerTimer`**
(INV-2).

### 4.3 Peripherals -> Mcu (timer clock)

The GPT channels are clocked from the Mcu clock tree via the
`GptClockReferencePoint_0` reference (Sec.2.3). The timer tick rate
therefore depends on the Mcu clock configuration, not on any Gpt-local
setting; the `value` (ticks) you pass to `Gpt_StartTimer` is interpreted
against that clock. Verify via
`nxp_s32ct_inspect(kind='xrefs', root_filter='Gpt')`.

### 4.4 Platform -> Interrupt Controller (interrupt mode only)

Enable the NVIC entry for the backing timer-IP instance (e.g. the PIT
instance) whose channel notification the model consumes. Verify the exact
IRQn names via the `.mex` Platform inspection -- do not assume. A
read-only design (elapsed/remaining reads with no `Gpt_EnableNotification`
and no ISR handler) does not require NVIC enablement.

### 4.5 Board Initialization (Simulink model)

Add via [`editing-mbdt-board-init`](../../../editing-mbdt-board-init/SKILL.md):

```
Component : Gpt
Priority  : 40
Enabled   : true
Header    : #include "Gpt.h"
Code      : Gpt_Init(&Gpt_Config);
```

AUTOSAR standard driver (`mode = autosar` in the `.mex`). `Gpt_Config` is
emitted by the code-gen tool from Peripherals -> Gpt. **GPT initializes
early (Priority 40), before Adc / Can / Pwm**, because the step and
profiler timers (INV-2) must be running first. Priority 40 is the default
emitted for the shipped example -- verify live via
`get_mbdt_board_init({family})`.

#### Expected generated C files (GPT)

A correctly-configured GPT peripheral must cause the config tool to emit
these generated units. If any are missing, the build fails at
compile/link time -- authoritative evidence of a config-tool-side
problem, NOT a model problem. Confirm the exact file names against the
generated `{model}_Config/` folder or the RTD Gpt component docs -- do
not cite from memory.

| Generated file | Emitted from | Flavor |
|---|---|---|
| `Gpt_Cfg.h` / `Gpt_PBcfg.*` | Peripherals -> Gpt (always) | GPT driver |
| `Pit_Ip_Cfg.h` / `Pit_Ip_Cfg.c` (or `Stm_Ip_Cfg.*`) | Peripherals -> Gpt, per backing timer-IP instance | backing timer IP |

**If `fatal error: Gpt_Cfg.h` (or `Pit_Ip_Cfg.h`) No such file appears at
build time:** the GPT flavor (or its backing-IP flavor) was not emitted.
Do NOT touch the model. Run
`nxp_s32ct_validate(project_path={.mex}, tool_name="Peripherals")`, read
the parsed problems, and re-generate.

#### RTD documentation (Integration + User Manual)

Read the **UM** and the **IM** before you modify the external
configuration tools project (S32CT / EB tresos), or before you implement
a user request the shipped examples do not cover. The **UM** tells you
how each `api_func` behaves, so you pick and drive the right function;
the **IM** covers generated-file expectations, init order, and NVIC
prerequisites. `{family_root}` = `mbd_find_{family}_root()`; glob RTD-
version segments (filenames are uppercased):

```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Gpt_TS_T40D*_M70I*_R0\doc\
    RTD_GPT_IM.pdf   RTD_GPT_UM.pdf
```

GPT is a single-module driver -- no cross-driver dependency block is
required (the backing timer IP such as PIT / STM is emitted as part of
the Gpt component, not a separately-configured driver).

---

## 5. Initialize Function Pattern


Start each application timer -- and, in interrupt mode, arm its
notification -- in the Initialize Function (channel names are
placeholders -- read the live enum):

```
Event Listener (EventType = Initialize)
    +-- Gpt_GetVersionInfo       (optional, diagnostic)
    +-- Gpt_StartTimer           channel = {GptChannelConfiguration_0}, value = {ticks}
    +-- Gpt_EnableNotification   channel = {GptChannelConfiguration_0}   (interrupt mode only)
```

- `Gpt_StartTimer` is what actually makes a channel count (INV-3); a pure
  elapsed/remaining polling design stops here.
- `Gpt_EnableNotification` is added only for interrupt-driven designs.
- **The Initialize Function does not call `Gpt_Init`** -- that runs from
  `mbdt_board_init.c` (Sec.4.5) at boot.
- Do **not** add `Gpt_StartTimer` blocks for `StepTimer` / `ProfilerTimer`
  -- the toolbox starts them (INV-2). Read the example's Initialize
  Function live before assuming.

---

## 6. Runtime Data Flow and Usage Patterns

Once the timer is started (Sec.5), the model consumes it in one of a few
ways. Channel names below are placeholders -- read them live from the
block enum.

### 6.1 Elapsed / remaining read (most common) -- no ISR

The default polling pattern: start once, sample every base-rate step. No
`Hardware_Interrupt_Handler` in the model and no NVIC enablement needed.
Used for timeouts, stopwatches, and elapsed-time-driven logic.

```
Initialize Function
   +-- Gpt_StartTimer       channel = {GptChannelConfiguration_0}, value = {ticks}

Top-level (runs at base rate)
   +-- Gpt_GetTimeElapsed   channel = {GptChannelConfiguration_0}   -- ticks so far
   +-- Gpt_GetTimeRemaining channel = {GptChannelConfiguration_0}   -- ticks left
```

### 6.2 Timer-expiry (interrupt) mode -- notify on target reached

Arm the notification at init, then route the expiry through an ISR
handler. For a **continuous** channel the notification recurs each
period (periodic-timer pattern); for a **one-shot** channel it fires once
(one-shot-delay pattern). One-shot vs continuous is set per channel in
Peripherals -> Gpt (Sec.4.2).

```
Initialize Function
   +-- Gpt_StartTimer         channel = {GptChannelConfiguration_0}, value = {period-or-delay-ticks}
   +-- Gpt_EnableNotification channel = {GptChannelConfiguration_0}

Timer reaches target -> notification -> NVIC -> ISR
   Hardware_Interrupt_Handler  irqGroup = Gpt, irqHandlers = {Gpt_PitNotification}
        | function-call trigger
        v
   Triggered Subsystem
        +-- (user logic: tick counter, restart timer, toggle output, ...)
```

The callback string is derived by the config tool from the **backing
timer IP** (INV-1): observed live on a PIT-backed channel as
`Gpt_PitNotification`; an STM-backed channel yields a different string.
Read `irqHandlers.Enum` live, never assume. Each timer notification in
use gets its own `Hardware_Interrupt_Handler` + triggered-subsystem pair
(Sec.7).

### 6.3 Predefined-timer read -- free-running microsecond time base

Reads a fixed-resolution free-running timer independent of the configured
channels -- useful as a microsecond timestamp source. Uses the `timer`
enum, not `channel`; needs no `Gpt_StartTimer`.

```
Top-level
   +-- Gpt_GetPredefTimerValue  timer = GPT_PREDEF_TIMER_1US_32BIT
```

### 6.4 Start / stop and power-mode / wakeup control

Runtime (re)start / halt of a channel, and low-power control:

```
Top-level
   +-- Gpt_StartTimer     channel = {ch}, value = {ticks}   -- (re)start
   +-- Gpt_StopTimer      channel = {ch}                     -- halt
   +-- Gpt_SetMode        mode = Sleep                        -- driver to low-power
   +-- Gpt_EnableWakeup   channel = {ch}, source = 0          -- let this timer wake the MCU
   +-- Gpt_CheckWakeup    source = 0                          -- query which source woke it
```

---

## 7. Interrupt Dependencies

1. **Interrupt mode:** one `Hardware_Interrupt_Handler` **per timer
   notification** consumed.
2. **Polling mode (elapsed / remaining):** no ISR handler in the model.
3. **`irqHandlers.Enum` under `irqGroup = Gpt` enumerates the timer
   notifications**, named by the backing IP (e.g. `Gpt_PitNotification`;
   INV-1). **Read the live `irqHandlers.Enum`, never assume the string.**
4. NVIC enablement: enable the backing timer-IP instance IRQn (e.g. the
   PIT IRQn) whose channel notification is consumed -- verify exact names
   via the `.mex`.

To wire a notification: add a `Hardware_Interrupt_Handler`, set
`irqGroup = Gpt`, then set `irqHandlers` to the exact notification name
from the live enum. GPT notifications **never** route through a parameter
on the `Gpt` block -- no `isr_*` / `callback_*` parameter exists on
`{family}_gpt`.

---

## 8. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| Channel logical name (application-chosen, plus `StepTimer` / `ProfilerTimer`) | Peripherals -> Gpt | `channel.Enum` on `Gpt` block |
| Backing timer IP (PIT / STM / ...) + IP channel index | Peripherals -> Gpt (channel under IP node) | Compiled-in; not exposed on block (surfaces only in `.mex` xrefs) |
| Channel mode (one-shot / continuous) + default target | Peripherals -> Gpt | Compiled-in; not exposed |
| Channel notification enable | Peripherals -> Gpt + block | Callback appears in `irqHandlers.Enum`; armed via `Gpt_EnableNotification` |
| Start target (ticks) | Simulink model | `value` on `Gpt_StartTimer` (or input port if `timer_value_input='on'`) |
| Predefined timer resolution | Peripherals -> Gpt | `timer` enum on `Gpt_GetPredefTimerValue` |
| Wakeup source | Peripherals -> Gpt + EcuM | `source` enum on `Gpt_*Wakeup` |
| Timer clock source | Peripherals -> Gpt -> `GptClockReferencePoint_0` -> Mcu | Compiled-in; not exposed |
| NVIC enable | Platform -> Interrupt Controller | Manifests as the timer notification firing |
| Operating mode (Normal / Sleep) | Simulink model | `mode` enum on `Gpt_SetMode` |
| Board-init entry `Gpt_Init(&Gpt_Config)` | `editing-mbdt-board-init` skill | Emitted into `mbdt_board_init.c` |

### 8.1 Cross-component links inside the `.mex`

The Gpt driver does not stand alone: its channels reference the backing
timer IP and the Mcu clock (all owned config-tool-side, visible only via
`nxp_s32ct_inspect(kind='xrefs')`). Read live -- never assume the exact
element names, which include application-chosen channel names.

| Link (source -> destination) | Reference path (destination) | Meaning |
|---|---|---|
| Gpt (internal) -> backing IP channel | `/Gpt/Gpt/GptChannelConfigSet/GptPit_0/GptPitChannels_M` | The timer-IP abstraction relation (INV-1) and the source of the block's `channel` enum (Sec.2.3) |
| Gpt -> Mcu (clock) | `/Gpt/Gpt/GptDriverConfiguration/GptClockReferencePoint_0` (-> Mcu clock tree) | Ties tick counts to real time (Sec.4.3) |
| Gpt -> EcuC / EcuM (partition / wakeup) | `/EcuC/...` , `/EcuM/...` | Which core / OS partition the Gpt driver is bound to, and the EcuM wakeup source for `Gpt_*Wakeup` |

---

## 9. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `channel` enum = "No ... configured" | Usually a **stale cached enum** on the linked block; only sometimes a genuinely undeclared channel | **First** `open_system({gptBlk})` + `pause(1)` and re-read (Sec.2.4). Only if still missing, declare it in Peripherals -> Gpt under a backing timer-IP node via `opening-mbdt-config-tool` |
| `StepTimer` / `ProfilerTimer` missing from the channel enum | INV-2 violated: the mandatory toolbox channels were removed or the model is not a proper MBDT GPT model | Restore them in Peripherals -> Gpt; re-open a shipped GPT example to compare |
| Build links but timer never counts | Missing board-init `Gpt_Init(&Gpt_Config)`, or no `Gpt_StartTimer` (INV-3) | Verify `Gpt_Init` in board init (Sec.4.5); add `Gpt_StartTimer` (Sec.5). Never stub `Gpt_Init` |
| `Gpt_GetTimeElapsed` returns a frozen / stale value | The channel was never started (INV-3) | Add `Gpt_StartTimer` for that channel in the Initialize Function |
| Timer expiry never fires | `Gpt_EnableNotification` missing, ISR handler missing, or the backing-IP IRQn disabled | Add `Gpt_EnableNotification` at init; add the ISR handler (`irqGroup = Gpt`, correct `Gpt_{IP}Notification`); enable NVIC (Sec.4.4, 7) |
| ISR fires but wrong subsystem runs | `irqHandlers` set to the wrong channel's notification | Read `irqHandlers.Enum` live; pick the exact `Gpt_{IP}Notification` name |
| Timer period is wrong even though `value` looks right | `value` (ticks) is interpreted against the Mcu-owned timer clock, which differs from the assumed rate | Verify the `GptClockReferencePoint_0` -> Mcu clock (Sec.4.3, 8.1); recompute ticks against the actual tick rate |
| Build fails: unresolved `Gpt_Init` / `Gpt_StartTimer` | Missing board-init entry | Add via `editing-mbdt-board-init`. Never stub the function |
| Build fails: `fatal error: Gpt_Cfg.h` / `Pit_Ip_Cfg.h` No such file | Config tool did not emit the GPT or backing-IP config unit | Do NOT edit the model. Run `nxp_s32ct_validate(project_path={.mex}, tool_name="Peripherals")`; read problems; re-generate. See Sec.4.5 |

---

## 10. Board-Specific Considerations

- **GPT drives no pins** (Sec.4.1) -- nothing to verify in Pins for a
  timeout / notification design.
- **Channel labels are application-named, except `StepTimer` /
  `ProfilerTimer`** (INV-2). Read the full set live.
- **The backing timer IP is config-tool-owned** (INV-1); on S32K3 every
  shipped GPT example is PIT-backed, STM is schema-supported but unused.
- **Cross-family portability.** The behavioral model (the live-discovered
  `api_func` set, the channel-based resource model, INV-1/INV-2/INV-3,
  per-channel expiry notifications, ISR routing through the family
  handler, the Mcu-owned timer clock) is expected to hold on S32K3.
  Family-specific differences to discover live:
  - board-init component name (`Gpt`) / header (`Gpt.h`) -- via
    `get_mbdt_board_init({family})`;
  - backing timer IP -- other families / projects may use STM or another
    counter, changing the `GptPit_0` -> `GptStm_0` node, the
    `Pit_Ip_Cfg.*` -> `Stm_Ip_Cfg.*` generated file, and the
    `Gpt_PitNotification` -> `Gpt_StmNotification` callback;

---

## 11. Guardrails (GPT-specific)

- **Never stub GPT functions.** Do not hand-write `Gpt_Init`,
  `Gpt_StartTimer`, `Gpt_StopTimer`, `Gpt_GetTimeElapsed`, any
  `Gpt_*Notification`, or any RTD function into generated C. The
  board-init entry (Sec.4.5) is what triggers MBDT to generate the driver
  code.
- **Never remove the mandatory `StepTimer` / `ProfilerTimer` channels**
  (INV-2).
- **A configured channel must be started** (INV-3).
- **Never invent channel names.** `GptChannelConfiguration_N` are
  application-chosen and vary per project; `StepTimer` / `ProfilerTimer`
  are the fixed exceptions. Read them all from the block's live enum.
- **The backing timer IP lives in the config tool, not on the block**
  (INV-1). Do not look for it on the `Gpt` block.
- **Never route a GPT notification through a parameter on the `Gpt`
  block.** All GPT timer notifications go through the
  `Hardware_Interrupt_Handler` block, and
  `irqHandlers` must be the exact live `Gpt_{IP}Notification` name
  (Sec.7).
- **Set `api_func` first**, before any resource enum.
- **Never set `text` on any `Gpt` block** -- system-managed.
