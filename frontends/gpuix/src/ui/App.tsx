/**
 * The root: one window, four surfaces. Hidden renders an empty search bar so
 * the frame left in the window is the one the next summon should show; every
 * row, entry and image is unmounted, which is what lets GPUI drop them.
 */
import { Board } from "./Board";
import { useServices } from "./context";
import { GuidancePanel } from "./GuidancePanel";
import { SearchPanel } from "./SearchPanel";

export function App() {
  const { controller } = useServices();
  if (controller.surface === "board") return <Board />;
  if (controller.surface === "guidance") return <GuidancePanel />;
  return <SearchPanel />;
}
