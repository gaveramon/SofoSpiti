import { createHash } from "node:crypto";
import { PermanentError, RetryableError, AuthExpiredError } from "../errors.ts";
import { fetchChecked } from "../http.ts";
import { getSecret } from "../vault.ts";
import type { Integration } from "../tokens.ts";
import { canonicalType, type DeviceAdapter } from "./types.ts";

export const DEFAULT_BASE = "https://open-ger.aqara.com/v3.0/open/api"; // EU

const md5 = (s: string) => createHash("md5").update(s).digest("hex");

async function creds() {
  const appId = await getSecret("oauth_client_id_aqara");
  const appKey = await getSecret("oauth_client_secret_aqara");
  const keyId = await getSecret("aqara_key_id");
  if (!appId || !appKey || !keyId) {
    throw new PermanentError("vault needs oauth_client_id_aqara, oauth_client_secret_aqara and aqara_key_id", "no_client");
  }
  return { appId, appKey, keyId };
}

export async function aqaraCall(base: string, token: string | null, body: unknown) {
  const { appId, appKey, keyId } = await creds();
  const nonce = crypto.randomUUID().replace(/-/g, "");
  const time = Date.now().toString();
  let s = token ? `Accesstoken=${token}&` : "";
  s += `Appid=${appId}&Keyid=${keyId}&Nonce=${nonce}&Time=${time}${appKey}`;
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Appid: appId, Keyid: keyId, Nonce: nonce, Time: time,
    Sign: md5(s.toLowerCase()),
  };
  if (token) headers.Accesstoken = token;
  const res = await fetchChecked(base, { headers, body: JSON.stringify(body) });
  const j = await res.json();
  const code = Number(j?.code ?? 0);
  if (code === 0) return j;
  if (code === 108) throw new AuthExpiredError("aqara access token expired");
  const msg = `aqara code ${code}: ${j?.message ?? j?.msgDetails ?? ""}`;
  if ([302, 303, 304].includes(code)) throw new RetryableError(msg, `aqara_${code}`); // rate / device offline class
  throw new PermanentError(msg, `aqara_${code}`);
}

const DEFAULT_RES = {
  turn_on: { resourceId: "4.1.85", value: "1" },
  turn_off: { resourceId: "4.1.85", value: "0" },
};

export const aqara: DeviceAdapter = {
  async execute(cmd, ctx) {
    const base = ctx.integ.provider_api_base_url ?? DEFAULT_BASE;
    const t = canonicalType(cmd.type);
    let res: { resourceId: string; value: string };
    if (t === "set_resource") {
      if (!cmd.payload?.resourceId) throw new PermanentError("payload.resourceId required", "bad_payload");
      res = { resourceId: String(cmd.payload.resourceId), value: String(cmd.payload.value ?? "") };
    } else if (t === "turn_on" || t === "turn_off") {
      res = ctx.deviceConfig?.resources?.[t] ?? DEFAULT_RES[t];
    } else if (ctx.deviceConfig?.resources?.[t]) {
      res = ctx.deviceConfig.resources[t]; // per-device mapping, e.g. lock/unlock for a specific model
    } else {
      throw new PermanentError(
        `aqara command '${cmd.type}' needs device_integration_map.config.resources.${t} = {resourceId,value}`,
        "unsupported_command",
      );
    }
    await aqaraCall(base, ctx.token, {
      intent: "write.resource.device",
      data: [{ subjectId: ctx.externalId, resources: [{ resourceId: res.resourceId, value: res.value }] }],
    });
    return { ok: true, action: t, resourceId: res.resourceId };
  },

  async refresh(integ: Integration, refreshToken: string) {
    const base = integ.provider_api_base_url ?? DEFAULT_BASE;
    return await aqaraCall(base, null, {
      intent: "config.auth.refreshToken",
      data: { refreshToken },
    });
  },
};
