import { always, eventually } from "@antithesishq/bombadil";
import { extract, weighted, type State } from "@antithesishq/bombadil/terminal";
import { pasteText } from "@antithesishq/bombadil/terminal/defaults/actions";
export { exitSuccess, noReplacementChars } from "@antithesishq/bombadil/terminal/defaults/properties";

type Observation = {
  commandId: string;
  kind: string;
  limit: number | null;
  ready: boolean;
  resultCount: number | null;
  scanning: boolean | null;
};

const emptyObservation: Observation = {
  commandId: "",
  kind: "starting",
  limit: null,
  ready: false,
  resultCount: null,
  scanning: null,
};

const latestObservation = extract((state: State): Observation => {
  const text = [
    ...Array.from({ length: state.scrollback.size.rows }, (_, row) => state.scrollback.rowText(row)),
    ...Array.from({ length: state.grid.size.rows }, (_, row) => state.grid.rowText(row)),
  ].join("\n");

  for (const line of text.split("\n").reverse()) {
    try {
      const value = JSON.parse(line.trim()) as Record<string, unknown>;
      if (value.type === "ready") {
        return { ...emptyObservation, kind: "ready", ready: true };
      }
      if (value.type !== "result" || typeof value.id !== "string" || typeof value.op !== "string") continue;
      const data = typeof value.data === "object" && value.data !== null
        ? value.data as Record<string, unknown>
        : {};
      const items = Array.isArray(data.items) ? data.items : null;
      return {
        commandId: value.id,
        kind: value.ok === true ? value.op : "error",
        limit: typeof data.limit === "number" ? data.limit : null,
        ready: value.op === "quiesce" && value.ok === true && data.scanning === false,
        resultCount: items?.length ?? null,
        scanning: typeof data.scanning === "boolean" ? data.scanning : null,
      };
    } catch {
      // Terminal state can contain a partially written JSONL record.
    }
  }
  return emptyObservation;
}).named("latest JSONL observation");

const commands = (...values: object[]) => pasteText(`${values.map(value => JSON.stringify(value)).join("\n")}\n`);
const command = (value: object) => commands(value);

export const terminalCommands = weighted([
  [10, command({ id: "init", op: "init", files: [
    { path: "alpha.txt", content: "alpha" },
    { path: "café/東京.txt", content: "unicode" },
    { path: "nested/duplicate.txt", content: "duplicate" },
  ] })],
  [6, command({ id: "query-alpha", op: "query", query: "alpha", offset: 0, limit: 20 })],
  [3, command({ id: "query-unicode", op: "query", query: "café", offset: 0, limit: 7 })],
  [2, command({ id: "query-empty", op: "query", query: "", offset: 0, limit: 1 })],
  [2, command({ id: "put-unicode", op: "put", path: "café/東京 alpha.txt", content: "alpha" })],
  [2, commands(
    { id: "put-before-rename", op: "put", path: "café/東京 alpha.txt", content: "alpha" },
    { id: "rename-unicode", op: "rename", from: "café/東京 alpha.txt", to: "café/renamed β.txt" },
  )],
  [2, command({ id: "remove-unicode", op: "remove", path: "café/renamed β.txt" })],
  [1, command({ id: "rebuild", op: "rebuild" })],
  [3, command({ id: "quiesce", op: "quiesce", timeout_ms: 2_000 })],
  [1, command({ id: "observe", op: "observe" })],
]);

export const noHarnessErrors = always(() => latestObservation.current.kind !== "error");

export const resultCountsStayWithinRequestedLimit = always(() => {
  const observation = latestObservation.current;
  return observation.resultCount === null ||
    (observation.limit !== null && observation.resultCount <= observation.limit);
});

export const resultsOnlyPublishWhenReady = always(() => {
  const observation = latestObservation.current;
  return observation.kind !== "query" || observation.resultCount !== null;
});

export const rebuildsFinishQuiescent = always(() => {
  const observation = latestObservation.current;
  return observation.kind !== "rebuild" || observation.scanning === false;
});

export const readinessIsReachable = eventually(() => latestObservation.current.kind === "ready");
