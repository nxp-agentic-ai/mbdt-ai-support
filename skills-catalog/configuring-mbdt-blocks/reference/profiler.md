# Profiler -- MBDT Block Reference

Measures elapsed time of an atomic region (atomic subsystem,
function-call subsystem, or initialize function). Cross-family
(S32K3); verified live on S32K3
(`s32k3xx_profiler_s32ct`).

## The 4 Profiler invariants

- **INV-1 -- No config-tool component.** Not a driver in S32CT / EB
  tresos. No init call in `mbdt_board_init.c`; the block emits its
  own code.
- **INV-2 -- Timer source is a model-setting choice.** Configuration
  Parameters -> Hardware Implementation -> Timers -> **Profiler
  timer** selects the counter the block reads. On S32K3 the live
  entries are `SysTick | GPT | DWT`; other families may expose a
  subset (e.g. only `SysTick` + `GPT`, or only `DWT`). Never assume
  a value -- read `Timers_ProfilerTimer` per model. When `GPT` is
  chosen, `Timers_ProfilerGptChannel` picks which GPT channel is
  used and MBDT auto-arms it; `SysTick` / `DWT` need no channel.
- **INV-3 -- Blocks pair by `index`.** Two blocks sharing the same
  `index` form a start / stop pair; the second computes the delta.
  Up to 100 independent probes (`0`..`99`).
- **INV-4 -- `showOut` decides ports.** `on` = one output in the
  selected unit; `off` = no ports, marker only.

> **Tip.** Open the shipped example via
> [`opening-mbdt-example`](../../../opening-mbdt-example/SKILL.md).
> Read the timer entries live via
> [`setting-mbdt-model-params`](../../../setting-mbdt-model-params/SKILL.md)
> (group `Timers`, tag `Timers_ProfilerTimer`) -- never carry the
> list from memory.

---

## 1. Peripheral Overview

| # | Artefact | Where | Owner |
|---|---|---|---|
| 1 | Profiler timer source | Model settings -> Timers -> `Timers_ProfilerTimer` (`SysTick` / `GPT` / `DWT` -- family-dependent) | This skill |
| 2 | GPT channel (only when timer = `GPT`) | Model settings -> `Timers_ProfilerGptChannel`; auto-armed by MBDT | This skill |
| 3 | `Profiler` pair (same `index`) | Around the atomic region | This skill |

---

## 2. The Profiler Block

MaskType `{family}_profiler` (S32K3: `s32k3_profiler`), library
reference `mbd_{family}_utility_library/Profiler Blocks/Profiler`.
No `api_func` pattern.

| Name | Type | Prompt | Semantics | Meaningful when |
|---|---|---|---|---|
| `index` | enum | Profiler index | `0`..`99` | Always |
| `timerName` | enum | Profiler timer | Read-only; mirrors `Timers_ProfilerTimer` | Always |
| `showOut` | boolean | Show output | on = expose delta; off = marker only | Always |
| `getUnit` | enum | Output unit | `Ticks` \| `Nanoseconds` \| `Microseconds` \| `Milliseconds` \| `Seconds` | `showOut = on` |

Ports: `showOut = on` -> `0 in / 1 out`; `showOut = off` ->
`0 in / 0 out`.

---

## 3. Configuration Workflow

1. Open Configuration Parameters -> Hardware Implementation ->
   Timers. Read the live entries of `Timers_ProfilerTimer` (S32K3:
   `SysTick | GPT | DWT`) and pick one. If `GPT`, set
   `Timers_ProfilerGptChannel`. Frequency (`Timers_ProfilerTimerFreq`)
   is read-only, driven by the clock configuration.
2. Place the region to measure inside an atomic container --
   atomic subsystem, function-call subsystem, or initialize
   function. Profiler measures the total execution time of that
   container.
3. Drop two `Profiler` blocks sharing `index`: first at the
   container entry (usually `showOut = off`), second at the exit
   (`showOut = on`, chosen `getUnit`). The second block's output
   is the delta between the two invocations.

Distinct `index` values measure independent regions in parallel.

#### RTD documentation (Integration + User Manual)

**Profiler has no RTD driver component** -- it is an NXP
add-on measurement block, not a Real-Time Drivers peripheral. There is
therefore **no `RTD_*_IM.pdf` / `RTD_*_UM.pdf` pair for Profiler**, no
config-tool container, and no init entry in `mbdt_board_init.c`
(INV-1). Do not fabricate an RTD PDF glob-path for it. The block's
behavior is documented with the MBDT toolbox itself.

The one exception is the **timer source**: when
`Timers_ProfilerTimer = GPT`, the underlying GPT channel that MBDT
auto-arms is a real RTD driver, documented in the Gpt PDFs.
`{family_root}` = `mbd_find_{family}_root()`; glob RTD-version
segments (filenames are uppercased):

```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Gpt_TS_T40D*_M70I*_R0\doc\
    RTD_GPT_IM.pdf   RTD_GPT_UM.pdf
```

The `SysTick` and `DWT` timer sources are core (Cortex-M) counters
with no RTD driver component.


The `s32k3xx_profiler_s32ct` example shows the canonical shape: a
function-call subsystem contains the marker probe, and the second
probe with `showOut = on` sits outside it -- delta = subsystem
execution time.

---

## 4. Runtime Data Flow

```
Atomic / function-call subsystem
    +-- Profiler(index=N, showOut=off)  -> capture T1
    | ... work ...
    +-- Profiler(index=N, showOut=on,   -> capture T2,
                 getUnit=Microseconds)     output = T2 - T1
```

Timer runs in hardware; the block just samples it.

#### Where the elapsed-time value is stored (FreeMASTER monitoring)

The `showOut = on` block writes the delta into a generated global array
`profiler_buffer[{index}]`, where `{index}` is exactly the block's
`index` parameter (`0`..`99`) -- one slot per probe pair. The block's
optional output port is just a tap of that same value. `profiler_buffer`
is a real global, so it lands in the ELF symbol table and is addressable
by name -- no signal naming or custom storage class needed.

To monitor from **FreeMASTER**: build and load the ELF (the shipped
example already has a `FreeMASTER Config` block), add
`profiler_buffer[{index}]` to a watch / oscilloscope using the same
`index` as the probe pair, and read it in the block's `getUnit`
(`Ticks` by default). See `freemaster.md` for wiring.

---

## 5. Correlation Matrix


| Setting | Owned by | Where in Simulink |
|---|---|---|
| Timer source (`SysTick` / `GPT` / `DWT`, per family) | Model settings -> Timers | `Timers_ProfilerTimer` (mirrored read-only in `timerName`) |
| GPT channel (only when timer = `GPT`) | Model settings -> Timers | `Timers_ProfilerGptChannel` |
| Probe pairing | `Profiler` block | Shared `index` |
| Output unit / visibility | `Profiler` block | `getUnit` / `showOut` |

Profiler is absent from the `.mex` (INV-1); when the timer source
is `GPT`, the GPT channel referenced in `Timers_ProfilerGptChannel`
is what appears in the `.mex`.

---

## 6. Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `timerName` on the block shows nothing / wrong value | `Timers_ProfilerTimer` never set for this model | Set it in Configuration Parameters -> Hardware -> Timers |
| Chosen timer entry rejected | That entry is not exposed on the current family | Read `Timers_ProfilerTimer` entries live; pick from what the family actually offers |
| Delta always `0` | No paired block, or paired block never executes | Add pair; ensure both run in the same atomic container |
| Delta huge / wraps | Timer wrapped between samples | Pick a wider counter (`GPT` over `SysTick`), coarser tick, or shorter region |
| Host cannot find the delta by name in the ELF | Embedded Coder folded it into `rtB.*` | Set output storage class to `ExportedGlobal` (or `Volatile`) -- see `freemaster.md` |

---

## 7. Board-Specific Considerations

- The list of profiler timer sources is family-specific. S32K3
  exposes `SysTick | GPT | DWT`; other families may omit one or
  more. Always read `Timers_ProfilerTimer` entries live per model.
- When `GPT` is chosen MBDT auto-arms the referenced channel -- no
  manual `Gpt_StartTimer` entry in `mbdt_board_init.c` is needed.
- `DWT` (Cortex-M Data Watchpoint & Trace cycle counter) is
  self-contained; `SysTick` shares the CPU core timer.

---

## 8. Guardrails

- Never look for Profiler in the config tool (INV-1).
- Never hardcode the timer source -- read `Timers_ProfilerTimer`
  live; only pick from the entries offered on the current family.
- Never add a Profiler init entry to `mbdt_board_init.c`; when the
  timer is `GPT`, MBDT arms the channel itself (INV-2).
- Every `showOut = on` block needs a paired block on the same
  `index` earlier in execution order; a lone block yields zero
  (INV-3).
- Place the probes around an atomic region (atomic / function-call
  subsystem or initialize function) -- non-atomic scoping produces
  an incoherent delta.
- Never set `timerName` on the block -- it is read-only, mirroring
  `Timers_ProfilerTimer`.
- To read the delta from FreeMASTER, give the output signal storage
  class `ExportedGlobal` (or `Volatile`).
