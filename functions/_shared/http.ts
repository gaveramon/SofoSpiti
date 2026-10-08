import { AuthExpiredError, PermanentError, RetryableError } from "./errors.ts";

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function safeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length) return false;
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}

/**
 * The scheduler calls with Authorization: Bearer <service_role_key>.
 * verify_jwt alone is not enough (the anon key is a valid JWT too),
 * so the key itself is compared.
 */
export function requireServiceRole(req: Request): Response | null {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const h = req.headers.get("authorization") ?? "";
  const token = h.startsWith("Bearer ") ? h.slice(7) : "";
  if (!key || !safeEqual(token, key)) return json({ error: "unauthorized" }, 401);
  return null;
}

export async function readLimit(req: Request, fallback: number, max: number) {
  let limit = fallback;
  try {
    const b = await req.json();
    const n = Number(b?.limit);
    if (Number.isFinite(n) && n > 0) limit = Math.floor(n);
  } catch { /* empty body */ }
  return Math.min(limit, max);
}

export interface FetchOpts {
  method?: string;
  headers?: Record<string, string>;
  body?: string;
  timeoutMs?: number;
}

/** fetch + timeout; network errors and 429/5xx become RetryableError. */
export async function fetchChecked(url: string, o: FetchOpts = {}): Promise<Response> {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), o.timeoutMs ?? 15000);
  let res: Response;
  try {
    res = await fetch(url, {
      method: o.method ?? "POST",
      headers: o.headers,
      body: o.body,
      signal: ctl.signal,
    });
  } catch (e) {
    throw new RetryableError(`network error: ${(e as Error).message}`, "network");
  } finally {
    clearTimeout(t);
  }
  if (res.status === 401) {
    await res.body?.cancel();
    throw new AuthExpiredError();
  }
  if (res.status === 429 || res.status >= 500) {
    const txt = (await res.text()).slice(0, 300);
    throw new RetryableError(`HTTP ${res.status}: ${txt}`, `http_${res.status}`);
  }
  if (res.status >= 400) {
    const txt = (await res.text()).slice(0, 300);
    throw new PermanentError(`HTTP ${res.status}: ${txt}`, `http_${res.status}`);
  }
  return res;
}

export const form = (o: Record<string, string | number | boolean | undefined>) =>
  new URLSearchParams(
    Object.entries(o)
      .filter(([, v]) => v !== undefined)
      .map(([k, v]) => [k, String(v)]),
  ).toString();

/** Run fn over items with limited concurrency and a global deadline. */
export async function pool<T>(
  items: T[],
  concurrency: number,
  deadlineMs: number,
  fn: (item: T) => Promise<void>,
) {
  const queue = [...items];
  const stop = Date.now() + deadlineMs;
  const skipped: T[] = [];
  const run = async () => {
    while (queue.length) {
      const it = queue.shift()!;
      if (Date.now() > stop) { skipped.push(it); continue; }
      await fn(it);
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, run));
  return skipped;
}
