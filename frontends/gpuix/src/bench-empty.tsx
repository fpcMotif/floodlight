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
const adopted = native.flg_adopt_window();
const material = native.flg_apply_material();
console.log("FLOODLIGHT_GPUIX empty_adopt=" + adopted + " empty_material=" + material);

setTimeout(() => {
  const shown = native.flg_show(680, 60);
  console.log("FLOODLIGHT_GPUIX empty_show_ms=" + shown.toFixed(2));
  native.flg_hide();
  setTimeout(() => native.flg_order_out(), 50);
  setTimeout(() => {
    Bun.gc(true);
    native.flg_release_memory();
  }, 1000);
  setTimeout(() => {
    const heap = heapStats();
    console.log("FLOODLIGHT_GPUIX empty_idle_footprint_mb=" + (native.fls_footprint_bytes() / 1048576).toFixed(2));
    console.log("FLOODLIGHT_GPUIX empty_idle_resident_mb=" + (native.fls_resident_bytes() / 1048576).toFixed(2));
    console.log("FLOODLIGHT_GPUIX empty_js_heap_mb=" + (heap.heapSize / 1048576).toFixed(2));
    process.exit(0);
  }, 11_000);
}, 1000);
