# DIO -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the DIO
(digital input/output) peripheral on any NXP MBDT-targeted Simulink
model. It describes the `Dio` block (`MaskType = {family}_dio`), the
Pins-tool / PORT-component / DIO-component three-way relation, how a
logical channel NAME on the block resolves to a physical pad, how the
DIO channel VALUE (`DioChannelId`) is calculated differently on S32K3
and other platforms, and why DIO has no `Dio_Init` and no interrupt of its own. The
behavioral model is expected to hold cross-family
(S32K3).

Read the sections in order: they walk from *what DIO is* -> *the block
model* -> *the Pins/PORT/DIO relation in the config tool* -> *board init*
-> *runtime read/write patterns*, then close with the per-family
channel-value arithmetic, a correlation matrix, troubleshooting, and
guardrails.

## The three DIO invariants (referenced throughout)

Three facts govern every DIO decision below. They are stated once here
and referenced by name; later sections do not re-derive them.

- **INV-1 -- DIO is channel-based with application-named channels; the
  block sees only the logical channel NAME plus a port selector.** The
  physical pad, the RTD channel ID (`DioChannelId`), and the pin's
  direction behind each channel name are **config-tool-owned** (Pins tool
  routes the pad as SIUL2 GPIO; Peripherals -> Dio names the channel and
  binds it to a DioPort) and surface only in the `.mex` (see the
  canonical tree in Sec.2.3). Channel names are application-chosen
  (`DioLed0`, `CanController_0_EN`, `SOFTLED_1`) and must be **read live,
  never assumed**.

- **INV-2 -- DIO has NO `Dio_Init` and no mandatory Initialize Function
  block. The pads are physically configured by `Port_Init` (the Port
  component).** DIO is not a driver that gets initialized on its own; on
  both families the board-init sequence contains a `Port` entry
  (priority ~30) and NO `Dio` entry. If `Port_Init` is missing, or the
  pad is not muxed as SIUL2 GPIO in the Pins tool, every `Dio_*` call is a
  silent no-op -- a runtime silence, not a build error.

- **INV-3 -- DIO has NO interrupt of its own.** There is no notification
  `api_func` on the `Dio` block and no ISR routing parameter. Edge / level
  interrupt detection on a pin is the **ICU** driver's job, not DIO's. A
  `Dio` block never connects to a `Hardware_Interrupt_Handler`.

> **Tip -- start from a shipped example.** Open a shipped DIO example via
> [`opening-mbdt-example`](../../../opening-mbdt-example/SKILL.md); its
> `.mex` project (Pins -> SIUL2 GPIO pads, Peripherals -> Dio channels,
> Peripherals -> Port for the pad setup) plus its model (a board-init
> `Port` entry, top-level `Dio_WriteChannel` / `Dio_ReadChannel` /
> `Dio_FlipChannel` blocks) forms a coherent end-to-end reference that
> mirrors the sections below. Always confirm behavior against a current
> model via live discovery (`get_mbdt_toolbox(family, 'examples')`,
> `get_param(..., 'DialogParameters')`, `nxp_s32ct_inspect`) -- never
> carry example names, channel names, or port labels from memory.

---

## 1. Peripheral Overview

Adding "DIO to a model" means placing several artefacts, not one block:

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT / EB tresos project (Pins -> route pad as SIUL2 GPIO, Peripherals -> Dio channels, Peripherals -> Port pad setup) | External to the model | External config tool |
| 2 | Board-init entry `Port_Init(&Port_Config)` (there is NO `Dio_Init`) | `mbdt_board_init.c`, emitted at code-gen | `editing-mbdt-board-init` skill |
| 3 | Runtime blocks: `Dio_WriteChannel` / `Dio_ReadChannel` / `Dio_FlipChannel` (and optionally `Dio_GetVersionInfo`) | Simulink model | This skill |

**Silent failure modes if any is missing:**

- Missing (1) -> block enums resolve to `"No channels configured"` /
  `"No ... configured"` sentinels on `channel` / `port` /
  `channel_group` (INV-1).
- Missing (2) -> build links but the pad is never muxed / configured, so
  every `Dio_*` call is a no-op; the pin never toggles (INV-2).
- Missing (3) -> no read or write is ever issued; no data flows.

**How DIO differs from other peripherals:** it has **no `Dio_Init` and no
mandatory Initialize Function block** (INV-2) -- the pad is brought up by
`Port_Init`, unlike ADC (which mandates `Adc_SetupResultBuffer`) or the
init-then-run peripherals; it is **flat and channel-based** (INV-1),
addressing one logical channel name at a time (no group hierarchy like
ADC); and it has **no interrupt of its own** (INV-3) -- pin edge/level
detection is delegated to the ICU driver. In the `.mex`, the `Dio` and
`Port` instances are largely **self-contained**: a standard xref scan
(`nxp_s32ct_inspect(kind='xrefs', root_filter='Dio')`) returns no
outgoing cross-references, unlike ADC / PWM which reference Mcu / EcuC /
Mcl.

---

## 2. The `Dio` Block -- Complete Behavioral Model

**One `Dio` block = one `Dio_*` function call.** Every block has
`MaskType = {family}_dio` (e.g. `s32k3_dio`) and is an
`S-Function`. A DIO usage in a model is composed of *several* `Dio`
blocks with different `api_func` values.

### 2.1 The `api_func` enum -- the function selector

**Always read the live `api_func.Enum`** via
`get_param({dioBlk}, 'DialogParameters')` -- the set of available
`Dio_*` functions is owned by the installed toolbox version and must
never be carried from memory. Whenever this reference names a specific
`Dio_*` function, treat it as an **illustrative** label; validate it
against the block's live `api_func.Enum` before selecting.

Observed live entries:

```
Dio_FlipChannel        Dio_GetVersionInfo      Dio_MaskedWritePort
Dio_ReadChannel        Dio_ReadChannelGroup    Dio_ReadPort
Dio_WriteChannel       Dio_WriteChannelGroup   Dio_WritePort
```

**Behavioral facts (independent of the exact function list):**

- **`Dio_WriteChannel`** drives a single logical channel high / low.
  Takes `channel`.
- **`Dio_ReadChannel`** reads the current level of a single logical
  channel. Takes `channel`.
- **`Dio_FlipChannel`** toggles a single logical channel and returns its
  new level. Takes `channel`.
- **`Dio_ReadPort` / `Dio_WritePort` / `Dio_MaskedWritePort`** read /
  write a whole port (a 16-bit half-port on S32K3) in one operation. Take `port`.
- **`Dio_ReadChannelGroup` / `Dio_WriteChannelGroup`** read / write a
  contiguous adjacent subset of a port defined as a channel group in the
  config tool. Take `channel_group` (reads `"No channel groups
  configured"` when none are declared -- expected, not an error).
- **`Dio_GetVersionInfo`** is diagnostic; needs no resource enum.
- Selecting `api_func` toggles the visibility of `channel` / `port` /
  `channel_group`. **Set `api_func` first.**

### 2.2 Parameter surface (constant across all `api_func` values)

| Name | Type | Prompt | Semantics | Meaningful for |
|---|---|---|---|---|
| `api_func` | enum | Function | Function selector (see Sec.2.1) | All |
| `channel` | enum | Channel | application-named logical channel (`DioLed0`, `CanController_0_EN`, `SOFTLED_1`) | `Dio_WriteChannel`, `Dio_ReadChannel`, `Dio_FlipChannel` |
| `port` | enum | Port | a port handle (S32K3 16-bit half-port `PTx_H` / `PTx_L`) | `Dio_ReadPort`, `Dio_WritePort`, `Dio_MaskedWritePort` |
| `channel_group` | enum | Channel Group | a contiguous subset of a port; reads `"No channel groups configured"` when none declared | `Dio_ReadChannelGroup`, `Dio_WriteChannelGroup` |
| `gpioSim` | boolean | Input Simulation Enable | enable input simulation for the channel (test aid) | read functions |
| `text` | string | *(empty)* | System-managed cache -- **never set** | Read-only |

The parameter set is constant across `api_func`; the mask shows / enables
only those meaningful for the selected function. Read live which are
enabled after setting `api_func`.

### 2.3 The resource enums and the canonical `.mex` layout

Observed live entries (illustrative -- read live before use; channel and
port names are **application-chosen** and will differ per project).

S32K3 example:

```
channel        : DioLed0 | DioLed1 | DioLed2 | DioButton0 | DioButton1
                 | DioLed3 | DioLed4 | CanController_0_EN | CanController_0_ERRN
                 | CanController_0_STB | CanController_1_EN | CanController_1_STB
                 | CanController_1_ERRN | DioLed5
port           : PTA_H | PTB_H | PTC_H | PTD_L | PTE_L      (16-bit half-ports)
channel_group  : (sentinel) "No channel groups configured"
```



**Canonical `.mex` layout (the single source rendering; all later
sections back-reference this).** The channel names are NOT stored on the
model and NOT fixed by the driver -- they are declared in the config-tool
project's Dio config tree and must be read from there (INV-1). Confirmed
live:

```
DioConfig/                              <- the Dio driver config set
    DioPort[]                           <- one node per port
        (S32K3) PTA_H (DioPortId 1), PTB_H (3), PTC_H (5), PTD_L (6), PTE_L (8)
        DioChannel[]                    <- channels nested under a DioPort
            Name          <- application-chosen (DioLed0, SOFTLED_1, ...)
            DioChannelId  <- the RTD channel index (see Sec.10 arithmetic)
            vGPIOSlot     <- virtual-wrapper slot (e.g. VIRTUAL_WRAPPER_PDAC0 / vGPIO1)
```

This is the **flat channel model** (INV-1): a `channel` handle on the
block maps to a `DioChannel` `Name` under some `DioPort`, and a `port`
handle maps to the `DioPort` node itself. The names read there are
exactly the strings that populate the block's `channel.Enum` /
`port.Enum` -- 1:1, case-sensitive. To read the live names for a project:

- `nxp_s32ct_inspect(kind='instances')` -- locate the `type_id = Dio`
  instance (and the sibling `type_id = Port` instance).

Note: a standard `nxp_s32ct_inspect(kind='xrefs', root_filter='Dio')`
returns **zero** cross-references -- the DIO channel-to-pad binding is
carried inside the `Dio` / `Port` instance bodies (DioChannelId +
vGPIOSlot), not as `value="/.../..."` xrefs. Read the instance body
directly when you need the `DioChannelId` values.

### 2.4 Sentinel rules

| `api_func` | resource sentinel = error? |
|---|---|
| `Dio_GetVersionInfo` | NO -- no resource needed |
| `Dio_ReadChannelGroup` / `Dio_WriteChannelGroup` | Only if you actually selected a group function -- `"No channel groups configured"` is otherwise expected |
| Everything else | YES (on the `channel` or `port` enum it actually uses) |

If `channel.Enum` (or `port.Enum`) reads `"No channels configured"` /
`"No ... configured"`, route to `opening-mbdt-config-tool` and declare
the channel in Peripherals -> Dio (and route its pad as SIUL2 GPIO in
Pins). `channel_group` legitimately reads `"No channel groups
configured"` on models that do not use channel groups -- that is
expected, not an error, unless you select a `*ChannelGroup` `api_func`.

> **Open the block first -- the sentinel is often just stale.** The `Dio`
> block is a **linked** library block; its resource enums are populated
> by a mask initialization callback that fires when the block dialog is
> *opened*. Reading an enum on a freshly loaded model can therefore
> return a cached `"No ... configured"` sentinel even when the config
> tool *has* declared the channel. When you hit a sentinel: first
> `open_system({dioBlk})` + a short `pause(1)`, re-read the enum, and only
> if the resource is still absent route to `opening-mbdt-config-tool`.

### 2.5 Selection ordering

1. `api_func` first -- toggles visibility.
2. `channel` (for channel functions) / `port` (for port functions) /
   `channel_group` (for group functions).
3. `gpioSim` if input simulation is wanted.

One `set_param` per parameter. Setting a resource enum before `api_func`
leaves it on a stale hidden slot and the model is incoherent.

---

## 3. Required Block Catalog

| Block name | `MaskType` | Role |
|---|---|---|
| `Dio` | `{family}_dio` | Wraps one `Dio_*` function; multiple instances per model |

DIO needs **no** ISR-handler block (INV-3) and **no** Initialize Function
block (INV-2). Pin edge / level interrupts, if needed, are the ICU
driver's job -- see the ICU reference, not this one. Discover exact block
paths via `detect_mbdt_blocks({family})`.

---

## 4. Configuration Workflow (config tool)

Steps 4.1-4.3 happen in the external configuration tool; board init
(Sec.4.5) and the model runtime blocks (Sec.6) follow. There is no NVIC
step (Sec.4.4) for DIO.

### 4.1 Pins

Route each pad used by a DIO channel as a **SIUL2 GPIO** signal. Pin
numbers are **board-specific** -- never invent them. Discover the live
pin mapping via `nxp_s32ct_inspect(kind='pins')` on the `.mex`.

- On **S32K3** a GPIO pad surfaces in the Pins tool as peripheral
  `SIUL2`, signal `gpio, N`, where `N` is the flat SIUL2 GPIO number
  (e.g. `PTA29 -> gpio 29`, `PTB18 -> gpio 50`). See Sec.10 for the
  `N = 32*portIndex + pinIndex` formula.

### 4.2 Peripherals -> Dio (declare the channels)

Declare each logical channel (per the canonical `.mex` tree in Sec.2.3):
give it a `Name` (`DioLed0`, `SOFTLED_1`, ...), bind it to a `DioPort`,
and the config tool assigns its `DioChannelId`. The **exact string
names** you assign here are what appear in the block's `channel.Enum` /
`port.Enum` -- case-sensitive, 1:1. Channel names are freely chosen by the
application -- read them live from the block enum, never assume a fixed
string. `type_id = Dio` (from `nxp_s32ct_inspect(kind='instances')`); the
shipped examples run the Dio driver in `autosar` mode.

### 4.3 Peripherals -> Port (the pad setup that replaces `Dio_Init`)

This is the **defining DIO relation** (INV-2). DIO has no init driver of
its own; the physical pad configuration -- direction (input / output),
pull, drive strength, and the SIUL2 GPIO mux -- is owned by the **Port**
component and applied at boot by `Port_Init` (Sec.4.5). The three-way
relation is:

```
Pins tool          declares the pad and muxes it as SIUL2 GPIO
     |                     (surfaces as gpio N / gp3n_{id})
     v
Port component     owns the pad's direction / pull / drive; emits Port_Init
     |                     (type_id = Port, mode = autosar)
     v
Dio component      names the logical channel and binds it to a DioPort;
                         DioChannelId points at the same physical pad
                         (type_id = Dio, mode = autosar)
```

Verify both instances exist via `nxp_s32ct_inspect(kind='instances')`:
a coherent DIO setup shows **both** a `type_id = Dio` and a
`type_id = Port` instance. If `Port` is missing, the pad is never
configured and every `Dio_*` call is a silent no-op.

### 4.4 Platform -> Interrupt Controller

**Not applicable to DIO** (INV-3). DIO has no interrupt of its own; no
NVIC entry is needed. If you need a pin edge / level interrupt, configure
the **ICU** driver instead (separate reference).

### 4.5 Board Initialization (Simulink model)

DIO has **no `Dio_Init`**. The board-init sequence on both families
carries a `Port` entry and NO `Dio` entry. Add / verify the `Port` entry
via [`editing-mbdt-board-init`](../../../editing-mbdt-board-init/SKILL.md):

```
Component : Port
Priority  : 30
Enabled   : true
Header    : #include "Port.h"
Code      : Port_Init(&Port_Config);
```

AUTOSAR standard driver (`mode = autosar` in the `.mex`). `Port_Config`
is emitted by the code-gen tool from Peripherals -> Port. Priority 30 is
the default emitted for the shipped examples -- verify live via
`get_mbdt_board_init({family})`. Confirmed: the S32K3 sequence
(Mcu 10, BaseNXP 20, **Port 30**, Gpt 40, Adc 50, ...) contain `Port` and
neither contains `Dio`.

#### Expected generated C files (DIO)

A correctly-configured DIO peripheral must cause the config tool to emit
these generated units. If any are missing, the build fails at
compile / link time -- authoritative evidence of a config-tool-side
problem, NOT a model problem. Confirm the exact file names against the
generated `{model}_Config/` folder or the RTD Dio / Port component docs
-- do not cite from memory.

| Generated file | Emitted from | Flavor |
|---|---|---|
| `Dio_Cfg.h` / `Dio_PBcfg.*` | Peripherals -> Dio (always) | DIO driver |
| `Port_Cfg.h` / `Port_PBcfg.*` | Peripherals -> Port (always) | PORT driver |
| `Siul2_Port_Ip_Cfg.*` | Pins -> SIUL2 GPIO | SIUL2 Port IP |

**If `fatal error: Dio_Cfg.h` (or `Port_Cfg.h`) No such file appears at
build time:** the flavor was not emitted. Do NOT touch the model. Run
`nxp_s32ct_validate(project_path={.mex}, tool_name="Peripherals")`, read
the parsed problems, and re-generate.

#### RTD documentation (Integration + User Manual)

Read the **UM** and the **IM** before you modify the external
configuration tools project (S32CT / EB tresos), or before you implement
a user request the shipped examples do not cover. The **UM** tells you
how each `api_func` behaves, so you pick and drive the right function;
the **IM** covers generated-file expectations and the pad / channel
model. `{family_root}` = `mbd_find_{family}_root()`; glob RTD-version
segments (filenames are uppercased):

```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Dio_TS_T40D*_M70I*_R0\doc\
    RTD_DIO_IM.pdf   RTD_DIO_UM.pdf
```

DIO has no `Dio_Init`; the physical pad configuration is owned by the
**Port** driver (`Port_Init`, Sec.4.3, Sec.4.5), documented in the Port
PDFs:

```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Port_TS_T40D*_M70I*_R0\doc\
    RTD_PORT_IM.pdf   RTD_PORT_UM.pdf
```

---

## 5. Initialize Function Pattern


**DIO has no mandatory Initialize Function block** (INV-2). Unlike ADC
(which mandates `Adc_SetupResultBuffer`), DIO needs nothing set up in the
model's Initialize Function -- the pad is brought up by `Port_Init` from
board init (Sec.4.5) before the model runs.

The only DIO block ever seen in a shipped Initialize Function is an
optional diagnostic `Dio_GetVersionInfo`; it needs no resource enum and
can be omitted. Read the example's Initialize Function live -- do not
assume any mandatory DIO init action.

---

## 6. Runtime Data Flow and Usage Patterns

Once the pad is configured by `Port_Init` (Sec.4.5), the model reads and
writes channels directly at the base rate. Channel names below are
placeholders -- read them live from the block enum.

### 6.1 Single-channel write / read / flip

```
Top-level (runs at base rate)
   +-- Dio_WriteChannel   channel = {DioLed2}    -- drive a channel high/low (input: level)
   +-- Dio_ReadChannel    channel = {DioButton0} -- read a channel's level (output: level)
   +-- Dio_FlipChannel    channel = {DioLed0}    -- toggle a channel, return new level
```

No ISR, no init action, no NVIC. This is the entire common DIO pattern:
place a `Dio_WriteChannel` / `Dio_ReadChannel` / `Dio_FlipChannel` block,
set `api_func`, set `channel`, wire the data port.

### 6.2 Whole-port and channel-group operations

```
Top-level
   +-- Dio_WritePort        port = {PTA_H / CRS_GPIO1}   -- write a whole port at once
   +-- Dio_ReadPort         port = {PTA_H / CRS_GPIO1}   -- read a whole port
   +-- Dio_MaskedWritePort  port = {PTA_H}               -- write only masked bits
   +-- Dio_WriteChannelGroup channel_group = {group}     -- write a contiguous subset
```

Port and channel-group operations exist for atomic multi-bit access.
`channel_group` requires a group declared in the config tool; without one
its enum reads `"No channel groups configured"` (Sec.2.4).

### 6.3 Input simulation

`gpioSim = true` on a read block enables input simulation for that
channel -- a test aid that lets the model drive a synthetic input level.
Leave `false` for hardware reads.

---

## 7. Interrupt Dependencies

**DIO has none** (INV-3). There is no notification `api_func` on the
`Dio` block, no `irqGroup = Dio`, and no ISR-handler wiring. A `Dio`
block never connects to a `Hardware_Interrupt_Handler` /
`ISR Handler`. Pin edge / level interrupt detection is provided by the
**ICU** driver, which is a separate peripheral with its own reference. If
a task needs "interrupt on a GPIO pin", that is an ICU task, not a DIO
task.

---

## 8. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| Channel logical name (application-chosen) | Peripherals -> Dio | `channel.Enum` on `Dio` block |
| Channel-to-pad binding + `DioChannelId` | Peripherals -> Dio (+ Pins mux) | Compiled-in; not exposed on block (in `.mex` DioChannel node) |
| Port handle (`PTx_H` / `PTx_L` / `CRS_GPIOn`) | Peripherals -> Dio (DioPort) | `port.Enum` on `Dio` block |
| Channel group (contiguous subset) | Peripherals -> Dio | `channel_group.Enum` on `Dio` block |
| Pad direction / pull / drive strength | Peripherals -> Port | Compiled-in; applied by `Port_Init` (INV-2) |
| SIUL2 GPIO pin muxing | Pins | Compiled-in; not exposed |
| Board-init entry `Port_Init(&Port_Config)` | `editing-mbdt-board-init` skill | Emitted into `mbdt_board_init.c` (there is NO `Dio_Init`) |
| Input simulation | Simulink model | `gpioSim` on read blocks |

### 8.1 Cross-component links inside the `.mex`

Unlike ADC / PWM, the `Dio` and `Port` instances hold **no outgoing
cross-references** in the standard xref scan
(`nxp_s32ct_inspect(kind='xrefs', root_filter='Dio')` and `root_filter=
'Port'` both return zero). The channel-to-pad binding is instead carried
**inside the instance bodies**:

- The `Dio` instance body holds `DioConfig -> DioPort[] -> DioChannel[]`
  with each channel's `Name`, `DioChannelId`, and `vGPIOSlot` (Sec.2.3).
- The `Port` instance body holds the per-pad direction / pull / mux that
  `Port_Init` applies.
- The Pins tool holds the SIUL2 GPIO mux that ties the pad to a GPIO
  number (S32K3 `gpio N`).

The three are correlated by the physical pad, not by a `.mex` xref. To
confirm a binding, read the `DioChannelId` from the `Dio` instance body
and cross-check it against the Pins `gpio` number using the Sec.10
arithmetic.

---

## 9. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `channel` / `port` enum = "No ... configured" | Usually a **stale cached enum** on the linked block; only sometimes a genuinely undeclared channel | **First** `open_system({dioBlk})` + `pause(1)` and re-read the enum (Sec.2.4). Only if still missing, open config tool via `opening-mbdt-config-tool` and add it in Peripherals -> Dio (+ route the pad as SIUL2 GPIO in Pins) |
| `channel_group` enum = "No channel groups configured" | **Expected** on models that do not use channel groups | Ignore, unless you select a `*ChannelGroup` `api_func` |
| Build links but the pin never toggles | Missing `Port_Init` entry, or pad not muxed as SIUL2 GPIO (INV-2) | Verify the `Port` board-init entry (Sec.4.5) and the SIUL2 GPIO mux in Pins. Never stub `Port_Init` |
| `Dio_ReadChannel` always returns the same level | Pad muxed to the wrong function, wrong direction in Port, or `gpioSim` left enabled | Check the Pins mux and Port direction; set `gpioSim = false` for a hardware read |
| Wrong pin toggles for a channel name | Channel name bound to the wrong `DioChannelId` / pad in the config tool | Read the `Dio` instance body `DioChannelId` and cross-check against the Pins `gpio` number (Sec.10) |
| Looking for "interrupt on GPIO" and finding no `Dio` notification | DIO has no interrupt (INV-3) | Use the **ICU** driver for pin edge / level interrupts, not DIO |
| Build fails: `fatal error: Dio_Cfg.h` / `Port_Cfg.h` No such file | Config tool did not emit the DIO / PORT config unit | Do NOT edit the model. Run `nxp_s32ct_validate(project_path={.mex}, tool_name="Peripherals")`; read problems; re-generate. See Sec.4.5 |

---

## 10. Board-Specific Considerations

The `DioChannelId` VALUE behind each channel name is computed. This is the key per-family DIO fact.

### 10.1 S32K3 -- flat SIUL2 GPIO number, half-port arithmetic

On S32K3 a pad's SIUL2 GPIO number is flat across the whole device:

```
gpio N = 32 * portIndex + pinIndex
         portIndex: PTA=0, PTB=1, PTC=2, PTD=3, PTE=4, PTF=5
         pinIndex : 0..31 within the port
```

The `Dio` block addresses a **16-bit half-port**: `PTx_H` covers pins
16..31 (base 16), `PTx_L` covers pins 0..15 (base 0). The stored
`DioChannelId` is the pin index **relative to the half-port base**:

```
physical pin index = half-port base + DioChannelId
                     base = 16 for PTx_H, 0 for PTx_L
gpio N             = 32 * portIndex + (base + DioChannelId)
```

Validated live:

- `DioLed0` under `PTA_H`, `DioChannelId = 13` -> pin 16+13 = PTA29 ->
  gpio 32*0+29 = **29** (matches Pins `gpio 29`).
- `DioLed3` under `PTB_H`, `DioChannelId = 2` -> pin 16+2 = PTB18 ->
  gpio 32*1+18 = **50** (matches Pins `gpio 50`).

So to resolve an S32K3 channel to a physical pad: read its `DioPort`
(gives portIndex + half-port base) and `DioChannelId` from the `Dio`
instance body, then apply the formula and cross-check against the Pins
`gpio N` value.


### 10.3 General


- **DIO pads vary per board.** Which physical pad backs each channel is
  board-specific -- verify against the model's `.mex` via
  `nxp_s32ct_inspect(kind='pins')` and the `Dio` instance body. Never
  invent pin numbers or `DioChannelId` values.
- **Channel and port labels are application-named** (INV-1). Read them
  live; do not assume a fixed naming scheme.
- **Cross-family portability.** The behavioral model (the live-discovered
  `api_func` set, the flat channel model, INV-1/INV-2/INV-3, pad setup by
  `Port_Init`, no interrupt of its own) is expected to hold on
  S32K3. Family-specific differences to discover live:
  - the channel-value arithmetic (S32K3 half-port `32*port+pin` -- above);
  - board-init component name (`Port`) / header (`Port.h`) -- via
    `get_mbdt_board_init({family})`.

---

## 11. Guardrails (DIO-specific)

- **Never stub DIO or PORT functions.** Do not hand-write `Port_Init`,
  `Dio_WriteChannel`, `Dio_ReadChannel`, `Dio_FlipChannel`, or any RTD
  function into generated C. The board-init `Port` entry (Sec.4.5) is
  what triggers MBDT to generate the driver code (INV-2).
- **Never expect a `Dio_Init`** (INV-2). DIO has no init driver; the pad
  is configured by `Port_Init`. A missing `Port` board-init entry -- not
  a missing `Dio_Init` -- is the cause of a silently dead pin.
- **Never invent channel / port names or `DioChannelId` values**
  (INV-1). Channel and port names are application-chosen and vary per
  project; read them from the block's live enums and the `Dio` instance
  body.
- **Compute the channel value with the right family formula** (Sec.10).
  S32K3 uses `32*portIndex + (half-port base + DioChannelId)`.
- **Never look for a DIO interrupt** (INV-3). DIO has no notification and
  no ISR routing; pin edge / level interrupts are the ICU driver's job.
- **Set `api_func` first**, before any resource enum.
- **Never set `text` on any `Dio` block** -- system-managed.
