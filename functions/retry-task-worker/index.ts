import { db } from "../_shared/db.ts";
import { errInfo, isPermanent, PermanentError } from "../_shared/errors.ts";
import { fetchChecked, json, pool, readLimit, requireServiceRole } from "../_shared/http.ts";

interface Task {
  id: string; tenant_id: string | null; handler: string; target_type: string | null;
  target_id: string | null; attempt: number; max_attempts: number; payload: Record<string, any> | null;
}

/**
 * Registered handlers. A retry task names its handler; unknown handlers fail
 * permanently with a clear message instead of silently doing nothing.
 *
 *   http_request | webhook : payload {url, method?, headers?, body?, timeout_ms?}
 *
 * Add a handler by adding a key here.
 */
const handlers: Record<string, (t: Task) => Promise<void>> = {
  async http_request(t) {
    const p = t.payload ?? {};
    const url = String(p.url ?? "");
    if (!/^https:\/\//i.test(url)) throw new PermanentError("payload.url must be an https URL", "bad_url");
    const method = String(p.method ?? "POST").toUpperCase();
    const hasBody = !["GET", "HEAD"].includes(method);
    const res = await fetchChecked(url, {
      method,
      headers: { "Content-Type": "application/json", ...(p.headers ?? {}) },
      body: hasBody ? JSON.stringify(p.body ?? {}) : undefined,
      timeoutMs: Number(p.timeout_ms ?? 15000),
    });
    await res.body?.cancel();
  },
};
handlers.webhook = handlers.http_request;

Deno.serve(async (req) => {
  const denied = requireServiceRole(req);
  if (denied) return denied;
  const limit = await readLimit(req, 20, 100);
  const sql = db();

  const tasks = await sql`select * from platform.claim_retry_task_batch(${limit})` as unknown as Task[];
  const tally = { done: 0, requeued: 0, failed: 0 };

  await pool(tasks, 4, 90_000, async (t) => {
    try {
      const h = handlers[t.handler];
      if (!h) throw new PermanentError(`no handler registered for '${t.handler}'`, "no_handler");
      await h(t);
      await sql`select platform.mark_retry_task(${t.id}, 'done', ${t.attempt + 1}, null)`;
      tally.done++;
    } catch (e) {
      const info = errInfo(e);
      const [r] = await sql`select platform.fail_retry_task(${t.id}, ${info.message}, ${isPermanent(e)}) as o`;
      if (r.o === "failed") tally.failed++; else tally.requeued++;
    }
  });
  return json({ claimed: tasks.length, ...tally });
});
