/**
 * The feasibility gate's floor (`--bench-empty`): the GPUIX window turned
 * into the panel with an empty tree and none of Floodlight loaded, shown and
 * hidden once, then idle for 10 s. What this prints is the cost of Bun,
 * React and GPUI before any search, history or icon.
 */
import { render } from "@gpuix/react";
import { heapStats } from "bun:jsc";
import { native } from "./platform/native";

render(<div style={{ width: "100%", height: "100%" }} />, {
  title: "Floodlight",
  width: 680,
  height: 60,
  windowBackground: "transparent",
  show: false,
  focus: false,
});
native.flg_start();

function report(key: string, value: number): void {
  console.log("FLOODLIGHT_GPUIX empty_" + key + "=" + value.toFixed(2));
}

/** GPUIX opens the window on a later run-loop pass than render(): retry. */
function adopt(tries: number): void {
  const adopted = native.flg_adopt_window();
  if (adopted <= 0 && tries > 0) {
    setTimeout(() => adopt(tries - 1), 50);
    return;
  }
  report("adopt", adopted);
  if (adopted <= 0) process.exit(1);
  report("material", native.flg_apply_material());
  setTimeout(measure, 1000);
}

function measure(): void {
  report("show_ms", native.flg_show(680, 60));
  native.flg_hide();
  setTimeout(() => native.flg_order_out(), 50);
  setTimeout(() => {
    Bun.gc(true);
    native.flg_release_memory();
  }, 1000);
  setTimeout(() => {
    const heap = heapStats();
    report("idle_footprint_mb", native.fls_footprint_bytes() / 1048576);
    report("idle_resident_mb", native.fls_resident_bytes() / 1048576);
    report("js_heap_mb", heap.heapSize / 1048576);
    process.exit(0);
  }, 11_000);
}

adopt(60);
