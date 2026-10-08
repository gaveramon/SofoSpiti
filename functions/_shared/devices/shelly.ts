import { PermanentError, RetryableError, AuthExpiredError } from "../errors.ts";
import { fetchChecked } from "../http.ts";
import { canonicalType, type DeviceAdapter } from "./types.ts";

/**
 * Shelly Cloud Control API v2. Base URL is the per-account host
 * (tenant_integrations.provider_api_base_url, from the token's user_api_url claim).
 */
export const shelly: DeviceAdapter = {
  async execute(cmd, ctx) {
    const base = ctx.integ.provider_api_base_url?.replace(/\/$/, "");
    if (!base) throw new PermanentError("shelly: provider_api_base_url missing; redo OAuth", "no_base_url");
    const t = canonicalType(cmd.type);
    if (t !== "turn_on" && t !== "turn_off") {
      throw new PermanentError(`shelly does not support command '${cmd.type}'`, "unsupported_command");
    }
    const channel = Number(cmd.payload?.channel ?? ctx.deviceConfig?.channel ?? 0);
    const res = await fetchChecked(`${base}/v2/devices/api/set/switch`, {
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${ctx.token}`,
      },
      body: JSON.stringify({ id: ctx.externalId, channel, on: t === "turn_on" }),
    });
    const j = await res.json().catch(() => ({}));
    if (j?.isok === false) {
      const msg = JSON.stringify(j.errors ?? j).slice(0, 300);
      if (/token|auth/i.test(msg)) throw new AuthExpiredError(msg);
      if (/offline|timeout|unreachable/i.test(msg)) throw new RetryableError(`shelly: ${msg}`, "shelly_offline");
      throw new PermanentError(`shelly: ${msg}`, "shelly_error");
    }
    return { ok: true, action: t, channel };
  },
};
