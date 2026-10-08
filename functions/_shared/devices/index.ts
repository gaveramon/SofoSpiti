import { aqara } from "./aqara.ts";
import { shelly } from "./shelly.ts";
import { ttlock } from "./ttlock.ts";
import type { DeviceAdapter } from "./types.ts";

export const adapters: Record<string, DeviceAdapter> = { ttlock, shelly, aqara };
export * from "./types.ts";
