/**
 * Floats under System Settings while the Full Disk Access list is open. The
 * app icon on the left is a native drag source (flg_drag_source covers it),
 * so granting is one drag into the list; the grant is detected by polling.
 */
import { GUIDANCE_DRAG } from "../app/controller";
import { FDA_JUST_GRANTED } from "../domain/fda";
import { CORNER_RADIUS, FONT_INSPECTOR_ROW, FONT_INSPECTOR_TITLE } from "../domain/metrics";
import { useServices } from "./context";
import { FONT } from "./theme";

export function GuidancePanel() {
  const { controller, icons, theme } = useServices();
  const bundle = controller.grantBundle();
  const name = bundle.split("/").pop()?.replace(/\.app$/, "") ?? "Floodlight";
  const granted = controller.fda.state === FDA_JUST_GRANTED;
  const icon = bundle.length > 0 ? icons.forPath(bundle) : "";
  const d = GUIDANCE_DRAG;
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        width: "100%",
        height: "100%",
        padding: 16,
        gap: 8,
        borderRadius: CORNER_RADIUS,
        backgroundColor: theme.surface,
      }}
    >
      <text style={{ fontSize: FONT_INSPECTOR_TITLE, fontFamily: FONT, fontWeight: 600, color: theme.primary }}>
        {granted ? "Full Disk Access granted" : "Allow Full Disk Access"}
      </text>
      <div style={{ display: "flex", flexDirection: "row", gap: 12, alignItems: "center", marginTop: d.y - 16 - 28 }}>
        {icon.length > 0 ? (
          <img src={icon} objectFit="contain" style={{ width: d.width, height: d.height }} />
        ) : (
          <div style={{ width: d.width, height: d.height }} />
        )}
        <text style={{ flexShrink: 1, fontSize: FONT_INSPECTOR_ROW, fontFamily: FONT, color: theme.secondary }}>
          {granted
            ? "Floodlight is reindexing your home folder."
            : "Drag " + name + " into the list above, then switch it on."}
        </text>
      </div>
    </div>
  );
}
