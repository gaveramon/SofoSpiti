import { createHash } from "node:crypto";
import { loadIntegration, getAccessToken } from "../tokens.ts";
import { aqara as aqaraDevice, aqaraCall, DEFAULT_BASE } from "../devices/aqara.ts";
import { getSecret } from "../vault.ts";
import { asString, type InboundProvider, type JsonObject } from "./types.ts";

const md5 = (s: string) => createHash("md5").update(s).digest("hex");

function deviceId(p: JsonObject): string | null {
  for (const c of [p.did, p.deviceId, p.deviceDid]) { const v = asString(c); if (v) return v; }
  const d = p.device;
  if (d && typeof d === "object" && !Array.isArray(d)) {
    for (const c of [(d as JsonObject).did, (d as JsonObject).deviceId]) { const v = asString(c); if (v) return v; }
  }
  // Aqara push payloads usually carry data: [{subjectId, ...}]
  if (Array.isArray(p.data)) {
    for (const x of p.data) { const v = asString((x as JsonObject)?.subjectId); if (v) return v; }
  }
  return null;
}

export const aqaraInbound: InboundProvider = {
  async verify(req) {
    const appkey = req.headers.get("appkey");
    const nonce = req.headers.get("nonce");
    const time = req.headers.get("time");
    const sign = req.headers.get("sign");
    if (!appkey || !nonce || !time || !sign) return false;
    // AppKey lives in Vault (shared with the Aqara OAuth client); env is a fallback.
    const configured = (await getSecret("oauth_client_secret_aqara")) ?? Deno.env.get("AQARA_APP_KEY");
    if (!configured || appkey !== configured) return false;
    const s = `appkey=${appkey}&nonce=${nonce}&time=${time}`.toLowerCase();
    return md5(s) === sign.toLowerCase();
  },

  parse(p) {
    return {
      providerCode: "aqara",
      externalEventId: asString(p.msgId),
      eventType: asString(p.msgType) ?? asString(p.eventType),
      externalAccountId: asString(p.openId),
      externalDeviceId: deviceId(p),
    };
  },

  async resolveIdentity(tenantId, did) {
    const integ = await loadIntegration(tenantId, "aqara");
    const token = await getAccessToken(integ, { refresh: aqaraDevice.refresh });
    const j = await aqaraCall(integ.provider_api_base_url ?? DEFAULT_BASE, token, {
      intent: "query.device.info",
      data: { dids: [did] },
    });
    const r = j?.result?.data?.[0] ?? j?.result?.[0] ?? {};
    const externalId = asString(r.did);
    const hardwareId = asString(r.mac);
    if (!externalId || !hardwareId) throw new Error("Aqara device info has no did/mac");
    return { externalId, hardwareId };
  },
};
