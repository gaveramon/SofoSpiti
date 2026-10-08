import type { Integration } from "../tokens.ts";

export interface CommandInput {
  id: string;
  type: string;
  payload: Record<string, any>;
}

export interface DeviceContext {
  tenantId: string;
  deviceId: string;
  externalId: string;
  deviceConfig: Record<string, any>; // device_integration_map.config
  integ: Integration;
  token: string;
}

export type DeviceAdapter = {
  /** Execute one command; return a result object (no secrets). */
  execute(cmd: CommandInput, ctx: DeviceContext): Promise<Record<string, unknown>>;
  /** Provider-specific token refresh (default: RFC 6749 refresh_token grant). */
  refresh?: (integ: Integration, refreshToken: string) => Promise<Record<string, any>>;
};

/** Command vocabulary understood by every adapter. */
export function canonicalType(t: string): string {
  const x = t.toLowerCase().trim();
  const map: Record<string, string> = {
    lock: "lock", unlock: "unlock",
    turn_on: "turn_on", on: "turn_on", switch_on: "turn_on",
    turn_off: "turn_off", off: "turn_off", switch_off: "turn_off",
    set_code: "set_code", create_code: "set_code", add_code: "set_code", generate_code: "set_code",
    delete_code: "delete_code", remove_code: "delete_code", revoke_code: "delete_code",
    set_resource: "set_resource",
  };
  return map[x] ?? x;
}

export function toMs(v: unknown, label: string): number {
  if (typeof v === "number") return v > 1e12 ? v : v * 1000;
  const ms = Date.parse(String(v));
  if (!Number.isFinite(ms)) throw new Error(`invalid ${label}`);
  return ms;
}
