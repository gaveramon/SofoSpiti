import { PermanentError, RetryableError, AuthExpiredError } from "../errors.ts";
import { fetchChecked, form } from "../http.ts";
import { getSecret } from "../vault.ts";
import { canonicalType, toMs, type DeviceAdapter } from "./types.ts";

const DEFAULT_BASE = "https://euapi.ttlock.com";

/** TTLock cloud API: form-encoded, errcode in the body (0 = ok). */
async function call(base: string, path: string, params: Record<string, string | number>) {
  const res = await fetchChecked(`${base}${path}`, {
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: form({ ...params, date: Date.now() }),
  });
  const j = await res.json();
  const code = Number(j?.errcode ?? 0);
  if (code === 0) return j;
  if (code === 10003 || code === 10004) throw new AuthExpiredError(`ttlock errcode ${code}`);
  // Parameter / permission errors will not fix themselves.
  if ([-1, -2, -3, 10001, 10007, 20002].includes(code)) {
    throw new PermanentError(`ttlock errcode ${code}: ${j?.errmsg ?? ""}`, `ttlock_${code}`);
  }
  // Lock offline / gateway issues etc.: bounded by max_retries.
  throw new RetryableError(`ttlock errcode ${code}: ${j?.errmsg ?? ""}`, `ttlock_${code}`);
}

export const ttlock: DeviceAdapter = {
  async execute(cmd, ctx) {
    const clientId = await getSecret("oauth_client_id_ttlock");
    if (!clientId) throw new PermanentError("vault oauth_client_id_ttlock missing", "no_client");
    const base = (ctx.integ.provider_api_base_url ?? DEFAULT_BASE).replace(/\/$/, "");
    const lockId = ctx.externalId;
    const common = { clientId, accessToken: ctx.token, lockId };
    const p = cmd.payload ?? {};

    switch (canonicalType(cmd.type)) {
      case "lock":
        await call(base, "/v3/lock/lock", common);
        return { ok: true, action: "lock" };
      case "unlock":
        await call(base, "/v3/lock/unlock", common);
        return { ok: true, action: "unlock" };
      case "set_code": {
        const code = String(p.code ?? p.pin ?? "");
        if (!/^\d{4,9}$/.test(code)) throw new PermanentError("payload.code must be 4-9 digits", "bad_code");
        if (!p.end_at && !p.valid_until) throw new PermanentError("payload.end_at is required", "bad_payload");
        const start = toMs(p.start_at ?? p.valid_from ?? Date.now(), "start_at");
        const end = toMs(p.end_at ?? p.valid_until, "end_at");
        if (end <= start) throw new PermanentError("end_at must be after start_at", "bad_payload");
        const j = await call(base, "/v3/keyboardPwd/add", {
          ...common,
          keyboardPwd: code,
          keyboardPwdName: String(p.name ?? `booking-${cmd.id.slice(0, 8)}`),
          startDate: start,
          endDate: end,
          addType: 2, // via gateway
        });
        return { ok: true, action: "set_code", keyboardPwdId: j.keyboardPwdId };
      }
      case "delete_code": {
        const id = p.keyboardPwdId ?? p.code_id ?? p.external_code_id;
        if (!id) throw new PermanentError("payload.keyboardPwdId (or code_id) is required", "bad_payload");
        await call(base, "/v3/keyboardPwd/delete", { ...common, keyboardPwdId: String(id), deleteType: 2 });
        return { ok: true, action: "delete_code" };
      }
      default:
        throw new PermanentError(`ttlock does not support command '${cmd.type}'`, "unsupported_command");
    }
  },
};
