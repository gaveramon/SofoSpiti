import postgres from "npm:postgres@3.4.4";

let _sql: ReturnType<typeof postgres> | null = null;

/**
 * Direct Postgres connection (service-level). The platform schema is
 * deliberately NOT exposed through PostgREST (RPC-only security model),
 * so the workers talk to Postgres themselves.
 * SUPABASE_DB_URL is injected by the Supabase edge runtime.
 */
export function db() {
  if (!_sql) {
    const url = Deno.env.get("SUPABASE_DB_URL");
    if (!url) throw new Error("SUPABASE_DB_URL is not set");
    _sql = postgres(url, {
      max: 3,
      prepare: false,
      idle_timeout: 20,
      connect_timeout: 10,
    });
  }
  return _sql;
}
