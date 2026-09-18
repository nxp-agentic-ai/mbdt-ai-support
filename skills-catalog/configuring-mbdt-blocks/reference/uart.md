# UART -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the UART
peripheral on any NXP MBDT-targeted Simulink model. This document
describes the behavior of the `Uart` block (`MaskType = {family}_uart`),
the ISR-handler wiring, the four common runtime modes (async, sync,
buffer, DMA), and the external-config-tool dependencies. The behavioral
model is expected to hold cross-family
(S32K3); exact enum labels and board-init
symbols may differ per family.
The UART examples shipped with the family MBDT toolbox are a good
starting point for confirming block behavior, wiring, and config-tool
setup.

> **Tip -- start from a shipped example.** Before building from scratch,
> open a UART example shipped with the family MBDT toolbox: its S32
> Configuration Tools project (Pins, Peripherals->Uart, Peripherals->Mcl
> for DMA, Interrupt Controller) and its Simulink model (board init,
> initialize function, callback subsystem, ISR wiring) already form a
> coherent end-to-end setup. Examples are listed and opened via the
> [`opening-mbdt-example`](../../../opening-mbdt-example/SKILL.md)
> skill; never carry example names from memory -- discover them at
> runtime.

---

## 1. Peripheral Overview

The UART peripheral in MBDT is a composite of four artefacts. Adding
"UART to a model" means placing all four, not one block:

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT / EB tresos project (Pins, Peripherals->Uart, NVIC; optionally Mcl->DMA channels) | External to the model | External config tool |
| 2 | Board-init entry `Uart_Init(&Uart_xConfig)` | `mbdt_board_init.c`, emitted at code-gen | `editing-mbdt-board-init` skill |
| 3 | Simulink `Initialize Function` subsystem -- priming call(s) that vary by mode | Simulink model | This skill |
| 4 | Runtime blocks: `Uart_Sync*` (inline) or `Uart_Async*` + `Hardware_Interrupt_Handler` + callback subsystem | Simulink model | This skill |

Failure modes if any is missing:

- Missing (1) -> block enums resolve to `"No channels configured"` sentinels.
- Missing (2) -> build links but `Uart_*` calls are no-ops; nothing on the wire.
- Missing (3, async mode) -> the ISR never fires because no buffer was ever registered.
- Missing (4) -> no data transfer.

**Key difference vs CAN:** UART has **no transceiver init** -- LPUART TX/RX go
directly to board pins routed by `Port_Init`. Section 7 of the CAN
reference has no UART counterpart.

---

## 2. The `Uart` Block -- Complete Behavioral Model

**One `Uart` block = one `Uart_*` function call.** Every block has
`MaskType = {family}_uart` (e.g. `s32k3_uart`) and is an `S-Function`.
A UART peripheral in a model is composed of *several* `Uart` blocks
with different `api_func` values.

### 2.1 The `api_func` enum -- the function selector

**Always read the live `api_func.Enum`** from the block in front of you
via `get_param({uartBlk}, 'DialogParameters')` -- the set of available
`Uart_*` functions is owned by the installed toolbox version and must
never be carried from memory.

**Behavioral facts an AI agent must know (independent of the exact
function list, which is discovered live):**

- **No `Uart_MainFunction_*`** -- sync sends/receives are the polling API.
- **Sync = synchronous / wait-for-completion** (functions of the shape `Uart_SyncSend` /
  `Uart_SyncReceive`). They consume the `timeout` parameter (us) and run
  to completion inside the enclosing subsystem's execution. A typical
  value is `10000` (10 ms).
- **Async = non-blocking** (`Uart_AsyncSend` / `Uart_AsyncReceive`).
  Completion is signalled through the ISR handler; the caller returns
  immediately.
- A `Uart_SetBuffer`-style function re-arms the driver's buffer pointer
  for the next transfer without allocating a new request. It is the
  **only** function where `transfer_type` (`UART_SEND` vs `UART_RECEIVE`)
  is meaningful.
- `Uart_SetBaudrate` / `Uart_GetBaudrate` (if present) are for runtime
  baud-rate changes; the initial baud rate comes from the config tool,
  not from the block.
- A `Uart_Abort`-style function cancels a pending async transfer. Not
  observed in any example.
- A `Uart_GetVersionInfo`-style function takes no channel -- reads
  module/vendor IDs into a Data Store for diagnostic readback.
- Selecting `api_func` reshapes the S-Function's ports and toggles the
  visibility of every other parameter. **Set `api_func` first.**

Whenever this reference names a specific `Uart_*` function below, treat
it as an **illustrative** label (for example, from an S32K3 example) --
validate it against the block's live `api_func.Enum` before selecting
it, and refuse near-misses.

### 2.2 Parameter surface (constant across all `api_func` values)

The parameter *names* are the same on every `Uart` block; only visibility and semantics change with `api_func`.

| Name | Type | Prompt | Semantics | Meaningful for |
|---|---|---|---|---|
| `api_func` | enum | Function | Function selector (see Sec.2.1) | All |
| `channel` | enum | Channel | `UartChannel_N` -- logical driver channel | All except `Uart_GetVersionInfo` |
| `baudrate` | enum | Baudrate | Fixed rate (see Sec.2.4) | `Uart_SetBaudrate` only |
| `transfer_type` | enum | Transfer Type | `UART_SEND` \| `UART_RECEIVE` | `Uart_SetBuffer` only |
| `timeout` | string | Timeout (us) | Transfer timeout in microseconds; must be a positive value | `Uart_SyncSend`, `Uart_SyncReceive` |
| `text` | string | *(empty)* | System-managed cache -- **never set** | Read-only |

### 2.3 The `channel` enum

Observed live entries in every model: `UartChannel_0 | UartChannel_1 | UartChannel_2`. **Do not confuse with LPUART instance numbers** -- the mapping is:

```
UartChannel_{N}  ->  UartChannelId = N  ->  {physical LPUART decided by config tool}
```

For example, `UartChannel_0` may back LPUART3 (pins PTE15/PTE16). The physical LPUART behind each channel is `UartChannelId` in the Peripherals -> Uart section of the config tool; **not** exposed on the block. Discover it by inspecting the `.mex` (`nxp_s32ct_inspect(kind='instances')`) or the EB tresos Uart module.

### 2.4 The `baudrate` enum

An enum-limited set of fixed rates. **Read the live `baudrate.Enum`**
from the block via `get_param({uartBlk}, 'DialogParameters')`; the exact
set of `UART_BAUDRATE_*` entries is owned by the installed toolbox
version -- never enumerate them from memory.

The value on the block **only matters for a `Uart_SetBaudrate`-style
function**. On every other function the enum stays at whatever the last
selection was and is ignored at runtime. The **initial** baud rate is set
in the config tool per channel, not on the block.

### 2.5 Sentinel rules

`channel.Enum == {"No channels configured"}` -- expected when the config
tool has not declared any `UartChannel_*`. It is an **error state** for
every function except `Uart_GetVersionInfo` (which takes no channel).

| `api_func` | `channel` sentinel = error? |
|---|---|
| `Uart_GetVersionInfo` | NO -- no channel needed |
| Everything else | YES |

> **Open the block first -- the sentinel is often just stale.** The `Uart`
> block is a **linked** library block, and its `channel` enum is populated
> by a mask initialization callback (`get_uart_channels`) that only fires
> when the block dialog is *opened*. Reading `channel.Enum` on a freshly
> loaded model can therefore return the cached `"No channels configured"`
> sentinel even when the config tool *has* declared channels. So when you
> hit the sentinel:
>
> 1. **First `open_system({uartBlk})`** (open the block dialog, then a short
>    `pause(1)`). This re-runs `get_uart_channels` and repopulates the
>    dropdown from `nxp.settings.get_param(modelPath,'uartChannels')`.
> 2. **Re-read `channel.Enum`.** In most cases the real `UartChannel_*`
>    entries now appear, and you can `set_param({uartBlk},'channel',...)`
>    directly -- no config-tool trip needed.
> 3. **Only if the channel you need is *still* absent after opening the
>    block** should you route to `opening-mbdt-config-tool` and declare a
>    `UartChannel_N` in Peripherals -> Uart.
>
> In short: opening the block fixes a *stale* enum; the config tool fixes a
> *genuinely undeclared* channel. Try the cheap fix first.

### 2.6 Selection ordering

1. `api_func` first -- reshapes ports and toggles visibility.
2. `channel` next.
3. `baudrate`, `transfer_type` (if the api_func requires them).
4. `timeout` last (string, must be set as a character vector like `'10000'`).

One `set_param` per parameter.

---

## 3. Required Block Catalog

| Block name | `MaskType` | Role |
|---|---|---|
| `Uart` | `{family}_uart` | Wraps one `Uart_*` function; multiple instances per model |
| `Hardware_Interrupt_Handler` | `{family}_isr_handler` | Routes the single `MBDT_Uart_Callback` into a function-call subsystem (async / buffer / DMA modes) |
| `FreeMASTER Config` (optional) | `{family}_fm_config` | Reserves an LPUART for FreeMASTER-over-serial -- **not** a `Uart` block |

Discover exact paths via `detect_mbdt_blocks({family})`.

---

## 4. Configuration Workflow (6 steps)

Steps 1-3 in the external configuration tool; steps 4-6 in the Simulink model.

### 4.1 Pins (S32 Configuration Tools -> Pins, or EB tresos -> Port)

Route the RX/TX pins for each LPUART instance in use:

```
LPUART{N}    lpuart{N}_rx  =  PT{port}{pin}
LPUART{N}    lpuart{N}_tx  =  PT{port}{pin}
```

Example (S32K344-Q257):

```
LPUART3    lpuart3_rx  = PTE15 (D2)      lpuart3_tx  = PTE16 (C2)
LPUART5    lpuart5_rx  = PTB28 (P10)     lpuart5_tx  = PTB27 (P9)
LPUART6    lpuart6_rx  = PTA15 (A11)     lpuart6_tx  = PTA16 (A12)   <- FreeMASTER default
LPUART13   lpuart13_rx = PTC27 (R16)     lpuart13_tx = PTC26 (P15)
```

Pin numbers are **board-specific** -- never invent them. Discover with `nxp_s32ct_inspect(kind='pins')`.

### 4.2 Peripherals -> Uart (S32 Configuration Tools -> Peripherals)

For each logical channel you plan to use in the model:

```
UartChannel_{N}                                  (the name the block will see)
    UartHwUsing        = LPUART_IP               (physical peripheral flavor)
    UartChannelId      = {LPUART instance number}
    UartClockRef       = /Mcu/.../UART_CLK       (which Mcu clock feeds it)
    UartAsyncMethod    = INTERRUPT | DMA         (synchronous-wait vs interrupt vs DMA)
    UartDefaultBaudrate = {initial baud}         (used until first Uart_SetBaudrate)
```

The **exact string names** you assign here (`UartChannel_0`, `UartChannel_1`, ...) are what appear in the Simulink block's `channel` enum. Case-sensitive, 1:1.

### 4.3 Peripherals -> Mcl -> DMA channel (DMA mode only)

If `UartAsyncMethod = DMA`, declare the DMA channel(s) in the Mcl driver
that the Uart driver will use. The model does not reference these DMA
channels directly -- the Uart driver picks them up internally. Optional
runtime monitoring blocks (`Mcl_GetDmaChannelStatus`,
`Mcl_GetDmaChannelParam`) are user-added if desired.

### 4.4 Platform -> Interrupt Controller (S32 Configuration Tools -> Platform)

For each LPUART instance used in async / buffer / DMA modes, enable the
NVIC entry:

```
LPUART{N}_IRQn                    e.g. LPUART3_IRQn, LPUART6_IRQn
```

Sync-only mode does not need NVIC enablement.

### 4.5 Board Initialization (Simulink model)

Add the UART driver init to `mbdt_board_init.c` via the
[`editing-mbdt-board-init`](../../../editing-mbdt-board-init/SKILL.md)
skill:

```
Component : Uart
Priority  : 120           (after Icu=110, before Lin_43_LPUART_FLEXIO=130)
Enabled   : true
Header    : #include "CDD_Uart.h"
Code      : Uart_Init(&Uart_xConfig);
```

Note the header is `CDD_Uart.h` (Complex Device Driver), not
`Uart_43_LPUART.h` -- the MBDT Uart wrapper is a CDD, not an AUTOSAR
standard driver. The config symbol `Uart_xConfig` is what the code-gen
tool emits from the Peripherals -> Uart module.

#### RTD documentation (Integration + User Manual)

Read the **UM** and the **IM** before you modify the external
configuration tools project (S32CT / EB tresos), or before you implement
a user request the shipped examples do not cover. The **UM** tells you
how each `api_func` behaves, so you pick and drive the right function;
the **IM** covers generated-file expectations, init order, and NVIC
prerequisites. `{family_root}` = `mbd_find_{family}_root()`; glob RTD-
version segments (filenames are uppercased):


```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Uart_TS_T40D*_M70I*_R0\doc\
    RTD_UART_IM.pdf   RTD_UART_UM.pdf
```

In DMA mode (`UartAsyncMethod = DMA`), the DMA channel(s) the Uart
driver picks up are configured in the **Mcl** driver; that configuration
is documented in the Mcl PDFs:

```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Mcl_TS_T40D*_M70I*_R0\doc\
    RTD_MCL_IM.pdf   RTD_MCL_UM.pdf
```

### 4.6 Model Initialize Function + Runtime Blocks (Simulink model)


Assemble the runtime side. Which blocks are needed depends on the
runtime mode -- see Sec.5 for the Initialize Function pattern and Sec.6 for
the runtime data-flow topology.

---

## 5. Initialize Function Patterns (mode-dependent)

Unlike CAN's fixed init sextet, UART's Initialize Function content
varies with the mode. Three observed patterns:

### 5.1 Async mode -- the standard case

```
+--- Event Listener (EventType = Initialize) ---------------------+
|                                                                  |
|   1. Uart_GetVersionInfo    channel = {any UartChannel}          |
|         (optional, diagnostic -- writes version to Data Store)    |
|                                                                  |
|   2. Uart_AsyncReceive      channel = UartChannel_0              |
|         (prime the first RX with a buffer pointer + length;      |
|          output "init_buffer" signal feeds the callback)         |
|                                                                  |
+------------------------------------------------------------------+
```

Two blocks total. **The Initialize Function does not call `Uart_Init`** --
that runs from `mbdt_board_init.c` (Sec.4.5) at boot, before the model's
Initialize Function.

### 5.2 Sync-only mode

```
Event Listener
    |
    +-- Uart_GetBaudrate    channel = UartChannel_0
            (diagnostic -- read what the config tool set)
```

One block. Sync sends/receives are self-contained; nothing to prime.

### 5.3 Buffer mode with intro banner

Same as async, plus a startup banner written via successive
`Uart_SyncSend` blocks:

```
Event Listener
    |
    +-- Uart_GetVersionInfo
    +-- Uart_SyncSend   "Intro Part 1"    timeout = positive value (e.g. 10000 us); zero is invalid
    +-- Uart_SyncSend   "Intro Part 2"
    +-- Uart_SyncSend   "Intro Part 3"
    +-- Uart_SyncSend   "Intro Part 4"
    +-- Uart_AsyncReceive  (prime first RX)
```

---

## 6. Runtime Data Flow

### 6.1 Async -- the canonical pattern

Set-up (Initialize Function, Sec.5.1) primes the first `Uart_AsyncReceive`
with a user-provided buffer. Runtime:

```
Byte arrives on wire -> LPUART FIFO -> RTD Uart driver fills user buffer ->
    |
    v
+----------------------------------------------------------------+
|  Hardware_Interrupt_Handler                                    |
|  ------------------------                                      |
|  irqGroup    = Uart                                            |
|  irqHandlers = MBDT_Uart_Callback                              |
|                                                                |
|  Outports (3):                                                 |
|    port 1  -- function-call trigger ----->|                    |
|    port 2  -- UART channel ID (usually terminated)             |
|    port 3  -- UART event code (Uart_StatusType) ----->|        |
+----------------------------------------------------------------+
                                            |        |
                                            v        v
+----------------------------------------------------------------+
|  UartCallback (function-call subsystem)                        |
|  ---------------------------------                             |
|  Inputs:                                                       |
|    trigger        = port 1 of ISR handler                      |
|    Input          = init_buffer signal (from Initialize Func)  |
|    In3 / Event    = port 3 of ISR handler (event code)         |
|                                                                |
|  Body (canonical shape):                                       |
|    If (event == RX_Ready) --> arm next RX                      |
|         -> Uart_SetBuffer(UART_RECEIVE) or Uart_AsyncReceive    |
|    If (event == TX_Ready) --> arm next TX (optional)           |
|         -> Uart_SetBuffer(UART_SEND) or Uart_AsyncSend          |
|    Uart_GetStatus (probe current channel state)                |
+----------------------------------------------------------------+
```

**Contrast with CAN's RX ISR handler** (which had 6 output ports carrying
`Hw Obj ID` and `Data`): UART's ISR handler has **no payload output** --
the payload is already in the user buffer registered by the prior
`Uart_AsyncReceive` / `Uart_AsyncSend`. The ISR only signals *what
event* happened (via port 3) so the callback can arm the next transfer.

### 6.2 Sync -- pure inline (no ISR)

```
Model base rate (periodic scheduler, or an enclosing subsystem)
    |
    v
Uart_SyncReceive     channel = UartChannel_0, timeout = 10000
    (waits up to 10 ms; delivers received bytes on its output port)
    |
    v
(user logic -- transformation, decision)
    |
    v
Uart_SyncSend        channel = UartChannel_0, timeout = 10000
    (waits up to 10 ms; drives bytes onto the wire)
```

**No `Hardware_Interrupt_Handler` in the model at all.**

### 6.3 Buffer mode

Same trigger topology as Sec.6.1. The difference is on the callback side:

- RX branch calls **`Uart_SetBuffer(UART_RECEIVE)`** to re-arm the same buffer with a new length, instead of `Uart_AsyncReceive` (which allocates a new request).
- TX branch calls **`Uart_SetBuffer(UART_SEND)`** to chain another payload from a circular buffer.

For example, `Uart_SetBuffer_Receive` and `Uart_SetBuffer_Continuation`
(TX, in multiple places) may share the same buffer memory.

### 6.4 DMA mode

**Block topology is identical to async (Sec.6.1).** The DMA aspect is
entirely a config-tool decision:

- `UartAsyncMethod = DMA` in Peripherals -> Uart.
- One or more DMA channels declared in Peripherals -> Mcl.

The `Uart` block itself has no `use_dma` parameter and no `Uart_DmaSend`
API. The optional `Mcl_GetDmaChannelStatus` / `Mcl_GetDmaChannelParam`
blocks are **status-monitoring** blocks, not required for DMA operation.

### 6.5 FreeMASTER-over-serial (LPUART shared with model?)

**No -- you cannot share an LPUART.** The `FreeMASTER Config` block
(`MaskType = {family}_fm_config`) reserves the LPUART instance passed to
its `instance` parameter (typically `LPUART_6`). If a `Uart` block's
`channel` also maps to that LPUART (via `UartChannelId` in the config
tool), both drivers try to service the same peripheral and the behavior
is undefined.

Rule: verify the `.mex` -- the `UartChannelId` of every `UartChannel_*`
must be distinct from the LPUART instance number in any
`FreeMASTER Config` block.

---

## 7. Interrupt Dependencies

1. **Async / buffer / DMA modes:** exactly one `Hardware_Interrupt_Handler` with `irqGroup = Uart, irqHandlers = MBDT_Uart_Callback` per model. All UART events (RX Ready, TX Ready, error, timeout) come through this single callback, demuxed by the event code on port 3.
2. **Sync-only mode:** no `Hardware_Interrupt_Handler` in the model.
3. **The `irqHandlers.Enum` under `irqGroup = Uart` has exactly one entry** (`MBDT_Uart_Callback`) -- unlike CAN, whose group exposes several. Do not expect the enum to grow with more selections. As always, confirm the entry live via `get_param({isrBlk}, 'DialogParameters')`.
4. Multi-channel async: still **one** ISR handler total. The event code on port 3 tells you which channel fired (in combination with port 2, if wired). All channels share the same callback subsystem.
5. NVIC enablement at the config-tool level: `LPUART{N}_IRQn` must be enabled per LPUART instance in use.

---

## 7.1 UART event codes delivered on ISR handler port 3

The `Uart_StatusType` integer emitted on output port 3 of the ISR
handler (when `irqGroup=Uart, irqHandlers=MBDT_Uart_Callback`) is what
the `UartCallback` subsystem's If-block dispatches on. Common event
constants:

| Event constant | Meaning | Emitted when |
|---|---|---|
| `END_TRANSFER` | An async transfer (Send OR Receive) has completed | The driver fires this single event and the callback demuxes TX-vs-RX via a `transfer_flag` Data Store variable |
| `RX_FULL` | An async receive has filled its buffer | Used when the driver is configured to report per-byte events |
| `TX_EMPTY` | An async send has drained its buffer | Companion to `RX_FULL` |

**Naming convention observation:** two different event-model conventions
are common:

1. **`END_TRANSFER`-only convention** -- the driver fires *once per completed transfer*; the callback subsystem uses a `transfer_flag` / `transferFlag` Data Store integer, set by the initiator (`Uart_AsyncReceive` = `1`, `Uart_AsyncSend` = `2`), to determine whether it was RX-done or TX-done. This is the more common convention.
2. **`RX_FULL` / `TX_EMPTY` convention** -- the driver fires distinct events for each direction, and the callback dispatches on the event code directly. Requires a matching config-tool setting (per-byte notification enabled).

Which convention applies to a specific model depends on how the Uart
driver is configured in the S32CT/EB tresos project. Do not assume one
convention when replicating the other. **Do not invent constants** --
read the constants used by the model's callback dispatch and treat
them as ground truth.

## 7.2 Data Store conventions in async / DMA callbacks

Async callbacks commonly use a small set of Data Store Memory variables
to coordinate between the Initialize Function, the callback subsystem,
and the runtime path. An AI agent replicating such a pattern should
preserve these:

| Variable | Type | Set by | Meaning |
|---|---|---|---|
| `transfer_flag` / `transferFlag` | integer | Initialize Function -> `Uart_AsyncReceive` (=1); DMA send-init -> `Uart_AsyncSend` (=2) | Direction of the most recently primed async transfer; the callback dispatches on it to decide whether to arm the next RX or the next TX |
| `signal_switch` / `triggered` | boolean | Callback's TX branch after first send | Selects which buffer address `Uart_AsyncSend` uses on subsequent transmits -- the initial buffer set in `Initialize Function`, or the newly filled buffer from the RX callback |
| `versionInfo` | struct | `Uart_GetVersionInfo` in Initialize Function | Module ID / vendor ID / vendor version -- for FreeMASTER readback |
| `data` (sync) or the sync-send data input | uint8 | `Uart_SyncReceive` output | Buffer for sync-mode transfer; consumed by the following `Uart_SyncSend` |
| `rx_buffer`, `rx_head`, `rx_tail`, `last_rx_char` | uint8[N] + integers | Buffer-mode callback | Circular-buffer state (bytes stored, head/tail indices, most recent RX character used for interaction-key detection) |
| `start_phase` | boolean | Buffer-mode callback | Flag distinguishing the first RX event (which comes from the initial `Uart_AsyncReceive` in Initialize Function) from steady-state RX events |

## 7.3 Expected host terminal settings

A UART link only works if the host-side terminal matches the initial
baud rate and framing. An AI agent explaining "the terminal shows
garbage" should first verify these match -- the block-side `baudrate`
enum is only used for runtime baud changes and does not reflect the
initial rate the host must match. A very common configuration is:

| Baud | Data / Stop / Parity / Flow |
|---|---|
| 115200 | 8 / 1 / None / None |
| 9600 | 8 / 1 / None / None |

The initial baud rate is compiled into `Uart_xConfig` from Peripherals ->
Uart -> `UartDefaultBaudrate`. Changing it in the config tool without
updating the terminal (or vice-versa) produces framing errors on the
first byte.

## 7.4 DMA mode -- LPUART pin considerations

A DMA-mode UART link commonly requires an external USB-to-serial
converter wired to specific LPUART pins on the debug header -- the pins
are board-specific. Discover the exact routing from the model's `.mex`
via `nxp_s32ct_inspect(kind='pins')`; for example, several S32K3 boards
route `LPUART3` to `PTE15` (RX) / `PTE16` (TX).

**Note:** a DMA UART link may deliberately use a different LPUART for
host communication than the one reserved for FreeMASTER. If a
`FreeMASTER Config` block is configured for one LPUART (e.g. `LPUART_6`)
and the `Uart` blocks for another (e.g. `LPUART_3`), both drivers coexist
without conflict.

## 8. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| Channel logical name (`UartChannel_0`) | S32CT/EB tresos Peripherals -> Uart | `channel.Enum` on `Uart` block |
| Physical LPUART instance (`UartChannelId = N`) | S32CT/EB tresos Peripherals -> Uart | Compiled-in; not exposed on block |
| Initial baud rate | S32CT/EB tresos Peripherals -> Uart -> `UartDefaultBaudrate` | Compiled-in; not exposed on block |
| Runtime baud change | Simulink model | `Uart_SetBaudrate` + `baudrate` enum |
| Async method (interrupt vs DMA) | S32CT/EB tresos Peripherals -> Uart -> `UartAsyncMethod` | Compiled-in; transparent to block |
| DMA channel assignment (DMA mode) | S32CT/EB tresos Peripherals -> Mcl | Compiled-in; not exposed on `Uart` block |
| RX/TX pin muxing (`lpuart{N}_rx/tx`) | S32CT/EB tresos Pins | Compiled-in; not exposed |
| Clock source | S32CT/EB tresos Peripherals -> Uart -> `UartClockRef` -> Mcu -> `UART_CLK` | Compiled-in; not exposed |
| NVIC enable (`LPUART{N}_IRQn`) | S32CT/EB tresos Platform -> Interrupt Controller | Manifests as `MBDT_Uart_Callback` firing |
| Transfer direction (buffer mode) | Simulink model | `transfer_type` on `Uart_SetBuffer` |
| Transfer timeout (sync mode) | Simulink model | `timeout` on `Uart_SyncSend` / `Uart_SyncReceive` |
| Board-init entry `Uart_Init(&Uart_xConfig)` | `editing-mbdt-board-init` skill | Emitted into `mbdt_board_init.c` |

---

## 9. Common Usage Patterns (block-topology cookbook)

### 9.1 Async echo (canonical)

```
Initialize Function
   +-- Uart_GetVersionInfo             (optional, diagnostic)
   +-- Uart_AsyncReceive  UartChannel_0 (prime first RX)

Runtime
   Hardware_Interrupt_Handler   irqGroup=Uart, irqHandlers=MBDT_Uart_Callback
        | trigger + event code
        v
   UartCallback (function-call subsystem)
        +-- If (event == RX_Ready) -> Uart_AsyncReceive (re-arm) or Uart_AsyncSend (echo)
        +-- If (event == TX_Ready) -> Uart_AsyncReceive (re-arm RX after TX)
        +-- Uart_GetStatus  (probe)
```

### 9.2 Sync loopback

```
Initialize Function
   +-- Uart_GetBaudrate  UartChannel_0   (diagnostic)

Runtime  (in a base-rate atomic subsystem)
   Uart_SyncReceive  UartChannel_0, timeout = 10000    -> received bytes
   (user logic)
   Uart_SyncSend     UartChannel_0, timeout = 10000    <- bytes to send
```

### 9.3 Circular buffer with intro banner

```
Initialize Function
   +-- Uart_GetVersionInfo
   +-- Uart_SyncSend   "Intro line 1"
   +-- Uart_SyncSend   "Intro line 2"
   +-- ... more sync sends for the banner ...
   +-- Uart_AsyncReceive  UartChannel_0

Runtime
   Hardware_Interrupt_Handler
        v
   UartCallback
        +-- If (event == RX_Ready)
        |     +-- Uart_SetBuffer  transfer_type = UART_RECEIVE  (re-arm same buffer)
        |         + user logic to update circular head/tail Data Stores
        +-- If (event == TX_Ready and buffer has pending data)
              +-- Uart_SetBuffer  transfer_type = UART_SEND    (chain next chunk)
```

### 9.4 DMA-backed async

Block topology identical to Sec.9.1. Additional config-tool setup:

```
Peripherals -> Uart -> UartChannel_{N} -> UartAsyncMethod = DMA
Peripherals -> Mcl -> DMA channel(s) reserved
```

Optional runtime observers (all `MaskType = {family}_mcl`):

```
Mcl_GetDmaChannelStatus       -> read TCD status
Mcl_GetDmaChannelParam        -> read channel parameters
Mcl_SetDmaInstanceCommand     -> pause / resume the whole DMA instance
```

### 9.5 Button-triggered send (LED-control example)

```
Initialize Function
   +-- Uart_AsyncReceive  UartChannel_0

Base-rate subsystem
   Dio_ReadChannel  DioButton0  -> If (pressed) -> Uart_SyncSend "LED0 ON\n"
   Dio_ReadChannel  DioButton1  -> If (pressed) -> Uart_SyncSend "LED0 OFF\n"

Runtime callback
   Hardware_Interrupt_Handler  irqGroup=Uart, irqHandlers=MBDT_Uart_Callback
        v
   UartCallback  (RX branch decodes command, drives Dio_WriteChannel LEDs)
```

Note the **mix of sync and async on the same channel** -- sync sends
coexist with async receives.

### 9.6 FreeMASTER-over-serial (informational)

```
FreeMASTER Config block  (MaskType = {family}_fm_config)
    connection_type = Serial
    instance        = LPUART_6           <- reserves this LPUART for FreeMASTER
    baudrate        = 115200
    mode            = Short Interrupt
```

The `FreeMASTER Config` block is **not** a `Uart` block and is unrelated
to this reference beyond one guardrail: **the LPUART instance you assign
to FreeMASTER must not also back a `UartChannel_*` used by any `Uart`
block in the model.**

---

## 10. Troubleshooting -- mapping symptoms to root causes

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `channel.Enum` on any `Uart` block reads `"No channels configured"` | Usually a **stale cached enum** on the linked block (callback hasn't fired); only sometimes a genuinely undeclared channel | **First** `open_system({uartBlk})` + `pause(1)` to fire `get_uart_channels` and re-read `channel.Enum` (Sec.2.5). Only if the channel is still missing, open config tool via `opening-mbdt-config-tool` and add it in Peripherals -> Uart |
| `channel.Enum` sentinel on `Uart_GetVersionInfo` | **This is expected** -- the function needs no channel | Ignore |
| Build links but nothing on the wire | Missing board-init entry `Uart_Init(&Uart_xConfig)` | Add via `editing-mbdt-board-init` (Sec.4.5). Never stub `Uart_Init` |
| Async model never receives anything (ISR never fires) | Missing `Uart_AsyncReceive` in the Initialize Function; no buffer registered | Add `Uart_AsyncReceive` as the last block in the Initialize Function (Sec.5.1) |
| Async ISR fires but callback subsystem runs on the wrong event | The callback dispatches on event code (port 3), but the If-block constants don't match the RTD event enum | Verify event-code constants against RTD `Uart_StatusType`; do not invent values |
| Build fails: unresolved `Uart_Init`, `Uart_AsyncSend`, `Uart_SetBuffer` | Board-init entry missing | Fix Sec.4.5. **Never** hand-stub the function |
| Sync send/receive does not complete | `timeout` is set to `0`, which is an **invalid** value for sync functions (see Sec.2.2). | Set `timeout` to `10000` or another positive microsecond value on every `Uart_SyncSend` / `Uart_SyncReceive` call. Validate the value; do not emit zero. |
| Baud rate is wrong at startup | Block's `baudrate` enum is ignored except by `Uart_SetBaudrate`; initial rate comes from config tool | Set `UartDefaultBaudrate` in Peripherals -> Uart |
| Multiple `Uart` blocks with different channels but only one works | Corresponding `LPUART{N}_IRQn` not enabled for the second channel | Enable NVIC entry in Platform -> Interrupt Controller |
| DMA-mode transfer stalls after N bytes | DMA channel misconfigured in Mcl, or DMA channel already reserved by another driver | Verify Peripherals -> Mcl DMA channel assignment; ensure exclusive to Uart |
| `FreeMASTER Config` and `Uart` block "fight" over the same LPUART | Both bound to the same LPUART instance | Reassign one to a different LPUART in the config tool |
| Callback subsystem receives trigger but garbage payload | User buffer overwritten between `Uart_AsyncReceive` and callback execution | Ensure the RX buffer is a persistent `Data Store Memory`, not a Simulink signal that can be re-evaluated |
| `Uart_SetBuffer` returns error status | `transfer_type` doesn't match the direction of the pending transfer | Set `transfer_type = UART_RECEIVE` for RX buffers, `UART_SEND` for TX buffers |
| MATLAB Function feeding `Uart_SyncSend.u1` fails with "Errors occurred during parsing of ..." | The function uses `sprintf`/`num2str` with a conversion spec (`%d`, `%s`, ...). A `%` in a MATLAB Function (Stateflow) chart is treated as a comment delimiter, and `sprintf('%d',...)` also produces a **variable-size** string that the default fixed-size chart rejects | Do **not** use `sprintf`/`num2str` to format text for UART. Emit into a **fixed-size** `uint8` buffer (e.g. `zeros(1,64,'uint8')`) and convert integers to ASCII digits manually (divide/mod loop, `+ uint8(48)`). Append CR/LF as `uint8(13)`, `uint8(10)`. |

---

## 11. Board-Specific Considerations

- **LPUART pin assignments vary per board.** `lpuart3_rx/tx` on S32K344-Q257 = `PTE15/PTE16`, but this differs on other packages. Discover from the model's `.mex` via `nxp_s32ct_inspect(kind='pins')`.
- **Channel-to-LPUART mapping is config-tool-owned.** The block sees only `UartChannel_0/1/2`; which physical LPUART is behind each is `UartChannelId` in the config tool. Do not assume `UartChannel_0` = LPUART0.
- **Some boards use LPUART for their debug console.** For example, a board may route UART to an on-board USB-serial converter -- verify the pin mapping matches the board schematic before deploying.
- **Cross-family portability.** The block behavioral model (the `api_func` function set discovered live, single ISR callback, sync/async/buffer/DMA modes) is expected to hold on S32K3, but the board-init component name (`Uart`) and the header (`CDD_Uart.h`) may differ. On some families the CDD Uart wrapper is named `Uart_43_LPUART` instead. Discover live via `get_mbdt_board_init({family})`.
- **No transceiver init exists for UART.** Unlike CAN (Sec.7 of the CAN reference), UART uses LPUART pins directly -- there is no external transceiver chip requiring GPIO wake-up or a helper C library. If a user asks about "UART transceiver initialization", the answer is "not applicable -- that is a CAN concept".

---

## 12. Guardrails (UART-specific -- supersedes nothing in parent SKILL.md)

- **Never stub UART functions.** Do not hand-write `Uart_Init`, `Uart_AsyncSend`, `Uart_SetBuffer`, `MBDT_Uart_Callback`, or any other Real-Time Driver function into generated C, the model, or a hand-written .c file. Adding the board-init entry (Sec.4.5) is what triggers MBDT to generate the driver code. If the build reports a missing UART symbol, the fix is **always** in the config tool or the board-init entry.

- **Never invent channel names.** `UartChannel_0`, `UartChannel_1`, `UartChannel_2` are exact strings owned by the config tool's Peripherals -> Uart section. Read them from the block's live `Enum`; if the string is not present, open the config tool.


- **`transfer_type` is meaningful only on `Uart_SetBuffer`.** Setting it on any other `api_func` is silently ignored; do not treat the default (`UART_SEND`) as significant on `Uart_SyncSend` etc.

- **The `timeout` parameter on `Uart_SyncSend` / `Uart_SyncReceive` must be a positive integer (e.g. `10000`).** On async functions it is silently ignored. Zero is not a valid parameter value for sync functions and must be rejected before any code is emitted. See also Sec.2.2 and the troubleshooting table (Sec.10).

- **`baudrate` on the block is meaningful only on `Uart_SetBaudrate`.** The initial baud rate is compiled into the driver's config structure from the config tool; changing `baudrate` on `Uart_AsyncSend` etc. has no runtime effect.

- **Never route the UART callback through a parameter on the `Uart` block.** No `isr_*`, `callback_*`, or `notification_*` parameter exists on `{family}_uart`. All UART callbacks go through the `Hardware_Interrupt_Handler` block (`ISR Handler` on S32N) with `irqGroup = Uart, irqHandlers = MBDT_Uart_Callback` -- the **only** entry in the enum for the Uart group.

- **Never set `text` on any `Uart` block.** It is system-managed (cached dump of the config tree, regenerated on the next mask refresh).

- **When multiple channels are active, still use exactly one ISR handler.** The single `MBDT_Uart_Callback` handles all UART events for all channels; the callback subsystem demuxes by event code and (optionally) by the channel-ID output on port 2. Do not add a second ISR handler for a second channel -- the enum has no second entry to select.

- **Verify LPUART instance exclusivity.** The LPUART number backing a `UartChannel_*` (via `UartChannelId`) must not also appear as the `instance` of a `FreeMASTER Config` block. Sharing an LPUART between the Uart CDD and the FreeMASTER driver produces undefined behavior.

- **`Uart_AsyncReceive` in the Initialize Function is not optional in async mode.** Without a priming async-receive call, the driver has no buffer to fill and the ISR never fires. The model will link cleanly and appear to run -- but the callback subsystem will never execute.
