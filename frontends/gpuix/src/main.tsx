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
export {};

if (process.argv.includes("--bench-empty")) {
  void import("./bench-empty");
} else {
  void import("./launch");
}
