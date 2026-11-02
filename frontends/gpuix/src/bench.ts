/**
 * The measure script's in-process run (`--bench`). Summons go through
 * `handleEvent`, the same handler a Carbon hotkey reaches, because a CI
 * runner cannot post a real key press without Accessibility; the time from
 * the HID event to that handler is not counted. Prints `FLOODLIGHT_GPUIX`
 * lines and exits.
 */
import { heapStats } from "bun:jsc";
import type { Controller } from "./app/controller";
import { native } from "./platform/native";

const WARMUP = 3;
const SUMMONS = 20;
const QUERIES = ["s", "sa", "saf", "safari", "read", "readme", "doc", "documents", "q3 report", "2*(3+4)"];
const IDLE_MS = 10_000;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function percentile(values: number[], p: number): number {
  const sorted = values.slice().sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length * p) / 100))];
}

function report(key: string, value: number | string): void {
  console.log("FLOODLIGHT_GPUIX " + key + "=" + (typeof value === "number" ? value.toFixed(2) : value));
}

export async function runBench(controller: Controller, hotkeys: number): Promise<void> {
  report("hotkeys", hotkeys);
  report("cold_start_ms", native.fls_process_age_ms());
  // Let the index open and the first frame land before timing anything.
  await sleep(2000);

  const summons: number[] = [];
  const queries: number[] = [];
  for (let i = 0; i < WARMUP + SUMMONS; i++) {
    const start = native.fls_now_ms();
    controller.handleEvent(1);
    const shown = native.fls_now_ms() - start;
    if (i >= WARMUP) summons.push(shown);
    for (const q of QUERIES) {
      const t = native.fls_now_ms();
      controller.setQuery(q);
      if (i >= WARMUP) queries.push(native.fls_now_ms() - t);
      await sleep(16);
    }
    controller.handleEvent(1);
    await sleep(100);
  }
  report("summon_p50_ms", percentile(summons, 50));
  report("summon_p95_ms", percentile(summons, 95));
  report("query_p50_ms", percentile(queries, 50));
  report("query_p95_ms", percentile(queries, 95));

  await sleep(IDLE_MS);
  const heap = heapStats();
  report("idle_footprint_mb", native.fls_footprint_bytes() / 1048576);
  report("idle_resident_mb", native.fls_resident_bytes() / 1048576);
  report("js_heap_mb", heap.heapSize / 1048576);
  report("js_heap_capacity_mb", heap.heapCapacity / 1048576);
  report("js_extra_memory_mb", heap.extraMemorySize / 1048576);
  process.exit(0);
}
