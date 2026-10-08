import { db } from "./db.ts";
import { PermanentError, RetryableError } from "./errors.ts";
import { fetchChecked, form } from "./http.ts";
import { getSecret, upsertSecret } from "./vault.ts";

export interface Integration {
  tenant_id: string;
  provider_code: string;
  credentials_ref: string | null;
  provider_api_base_url: string | null;
  config: Record<string, any>;
}

export async function loadIntegration(tenantId: string, provider: string): Promise<Integration> {
  const [r] = await db()`
    select tenant_id, provider_code, credentials_ref, provider_api_base_url, config
    from public.tenant_integrations
    where tenant_id = ${tenantId} and provider_code = ${provider} and is_enabled = true`;
  if (!r) throw new PermanentError(`integration ${provider} is not connected/enabled for tenant`, "no_integration");
  if (!r.credentials_ref) throw new PermanentError(`integration ${provider} has no credentials_ref`, "no_credentials");
  return r as unknown as Integration;
}

interface Tok { access: string; refresh?: string; expiresIn?: number; raw: Record<string, any> }

/** Accepts OAuth2 style and Aqara style ({result:{accessToken,...}}) token blobs. */
export function normalizeToken(raw: Record<string, any>): Tok {
  const o = raw?.result && typeof raw.result === "object" ? raw.result : raw;
  const access = o.access_token ?? o.accessToken;
  if (!access) throw new PermanentError("stored credentials contain no access token", "no_token");
  const exp = o.expires_in ?? o.expiresIn;
  return {
    access,
    refresh: o.refresh_token ?? o.refreshToken,
    expiresIn: exp !== undefined ? Number(exp) : undefined,
    raw,
  };
}

async function readStored(integ: Integration): Promise<Tok> {
  const s = await getSecret(integ.credentials_ref!);
  if (!s) throw new PermanentError(`vault secret ${integ.credentials_ref} not found`, "no_credentials");
  let raw: Record<string, any>;
  try { raw = JSON.parse(s); } catch { throw new PermanentError("stored credentials are not JSON", "bad_credentials"); }
  return normalizeToken(raw);
}

async function persist(integ: Integration, tok: Tok, merged: Record<string, any>) {
  await upsertSecret(
    JSON.stringify(merged),
    integ.credentials_ref!,
    `OAuth credentials for ${integ.provider_code} tenant ${integ.tenant_id} (refreshed)`,
  );
  if (tok.expiresIn !== undefined) {
    const at = new Date(Date.now() + tok.expiresIn * 1000).toISOString();
    await db()`
      update public.tenant_integrations
      set config = jsonb_set(
            coalesce(config, '{}'::jsonb), '{oauth}',
            coalesce(config->'oauth', '{}'::jsonb)
              || jsonb_build_object('token_expires_at', ${at}::text, 'token_refreshed_at', now()::text)),
          updated_at = now()
      where tenant_id = ${integ.tenant_id} and provider_code = ${integ.provider_code}`;
  }
}

export type CustomRefresh = (integ: Integration, refreshToken: string) => Promise<Record<string, any>>;

/** Generic RFC 6749 refresh_token grant using integration_oauth_configs. */
async function genericRefresh(integ: Integration, refreshToken: string) {
  const [cfg] = await db()`
    select token_url, client_auth_method from public.integration_oauth_configs
    where provider_code = ${integ.provider_code} and is_active = true`;
  if (!cfg) throw new PermanentError(`no oauth config for ${integ.provider_code}`, "no_oauth_config");
  const clientId = await getSecret(`oauth_client_id_${integ.provider_code}`);
  const clientSecret = await getSecret(`oauth_client_secret_${integ.provider_code}`);
  if (!clientId) throw new PermanentError(`vault oauth_client_id_${integ.provider_code} missing`, "no_client");
  const body: Record<string, string> = { grant_type: "refresh_token", refresh_token: refreshToken };
  if (cfg.client_auth_method !== "none") {
    body.client_id = clientId;
    if (clientSecret) body.client_secret = clientSecret;
  } else body.client_id = clientId;
  const res = await fetchChecked(cfg.token_url, {
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: form(body),
  });
  return await res.json();
}

/**
 * Returns a valid access token. Refreshes (and re-stores in Vault) when it
 * expires within 2 minutes, or when force=true (provider said 401).
 */
export async function getAccessToken(
  integ: Integration,
  opts: { force?: boolean; refresh?: CustomRefresh } = {},
): Promise<string> {
  const tok = await readStored(integ);
  const expAt = integ.config?.oauth?.token_expires_at
    ? Date.parse(integ.config.oauth.token_expires_at)
    : NaN;
  const nearExpiry = Number.isFinite(expAt) && expAt - Date.now() < 120_000;
  if (!opts.force && !nearExpiry) return tok.access;

  if (!tok.refresh) {
    if (opts.force) throw new PermanentError("token rejected and no refresh token stored; reconnect the integration", "reauth_required");
    return tok.access; // near expiry but cannot refresh: try anyway
  }
  const fresh = await (opts.refresh ?? genericRefresh)(integ, tok.refresh);
  const next = normalizeToken(fresh);
  if (!next.refresh) next.refresh = tok.refresh;
  const merged = { ...tok.raw, ...fresh };
  if (!(merged.refresh_token ?? merged.refreshToken)) merged.refresh_token = next.refresh;
  await persist(integ, next, merged);
  return next.access;
}

export { RetryableError };
