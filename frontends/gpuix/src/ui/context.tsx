import { createContext, useContext, useSyncExternalStore } from "react";
import type { Controller } from "../app/controller";
import type { IconCache } from "../platform/icons";
import { themeFor, type Theme } from "./theme";

export interface Services {
  controller: Controller;
  icons: IconCache;
  /** Where exported clipboard images go for the inspector. */
  imageDir: string;
}

export const ServicesContext = createContext<Services | null>(null);

/** The controller, re-rendering whenever it publishes. */
export function useServices(): Services & { theme: Theme } {
  const services = useContext(ServicesContext);
  if (services === null) throw new Error("ServicesContext is missing");
  const c = services.controller;
  useSyncExternalStore(c.subscribe, c.snapshot);
  return { ...services, theme: themeFor(c.dark, c.material === 0) };
}
