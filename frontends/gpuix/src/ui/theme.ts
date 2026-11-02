/**
 * Colours for light and dark, in one place, as `FloodlightMetrics` holds the
 * sizes. Text uses `primary` and `secondary`; `tertiary` is for placeholders
 * and disabled text only.
 */
export interface Theme {
  primary: string;
  secondary: string;
  tertiary: string;
  accent: string;
  selection: string;
  badgeFill: string;
  divider: string;
  /** The panel's own surface: transparent over glass, solid with Reduce Transparency. */
  surface: string;
  /** The clipboard board's opaque well inside the slab. */
  well: string;
  wellStroke: string;
  highlight: string;
}

export const FONT = ".SystemUIFont";

const DARK: Theme = {
  primary: "#ffffffeb",
  secondary: "#ffffff99",
  tertiary: "#ffffff59",
  accent: "#0a84ff",
  selection: "#ffffff1f",
  badgeFill: "#ffffff12",
  divider: "#ffffff1a",
  surface: "#00000000",
  well: "#1c1c1e",
  wellStroke: "#ffffff1f",
  highlight: "#0a84ff40",
};

const LIGHT: Theme = {
  primary: "#000000e0",
  secondary: "#0000008c",
  tertiary: "#00000052",
  accent: "#007aff",
  selection: "#0000001a",
  badgeFill: "#00000012",
  divider: "#0000001a",
  surface: "#00000000",
  well: "#ffffff",
  wellStroke: "#0000001f",
  highlight: "#007aff33",
};

/** `solid`: Reduce Transparency is on, so React paints the surface itself. */
export function themeFor(dark: boolean, solid: boolean): Theme {
  const base = dark ? DARK : LIGHT;
  if (!solid) return base;
  return { ...base, surface: dark ? "#1e1e1e" : "#f5f5f7" };
}
