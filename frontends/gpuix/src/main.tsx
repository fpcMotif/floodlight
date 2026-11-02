/**
 * Floodlight on GPUIX: waits hidden in the AppKit pump for ⌥Space or ⌥⇧C.
 *
 *   floodlight-gpuix                 indexes $HOME on first run, in the background
 *   floodlight-gpuix --root DIR      index a different folder
 *   floodlight-gpuix --bench         the measure script's run (scripts/measure.sh)
 *   floodlight-gpuix --bench-empty   the feasibility floor: an empty panel
 *
 * The floor run must not load Floodlight, so each mode is its own module.
 */
import { existsSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";

/**
 * `bun build --compile` cannot embed GPUIX's renderer: napi-rs picks the
 * platform's `.node` with a runtime `require`. bundle.sh puts it beside the
 * executable, and this points napi-rs at it before @gpuix/native loads.
 */
function useBundledRenderer(): void {
  if (process.env.NAPI_RS_NATIVE_LIBRARY_PATH !== undefined) return;
  const dir = dirname(process.execPath);
  const addon = readdirSync(dir).find((name) => name.startsWith("gpuix-native.") && name.endsWith(".node"));
  if (addon !== undefined && existsSync(join(dir, addon))) process.env.NAPI_RS_NATIVE_LIBRARY_PATH = join(dir, addon);
}

useBundledRenderer();
if (process.argv.includes("--bench-empty")) {
  void import("./bench-empty");
} else {
  void import("./launch");
}
