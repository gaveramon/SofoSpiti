import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";
import { db } from "../_shared/db.ts";
import { errInfo, isPermanent, PermanentError, RetryableError } from "../_shared/errors.ts";
import { json, pool, readLimit, requireServiceRole } from "../_shared/http.ts";
import { getJsonSecret } from "../_shared/vault.ts";

/**
 * Vault secret `smtp_config` (JSON):
 * {"host":"smtp.example.com","port":587,"secure":false,"username":"..","password":"..",
 *  "from":"Sofo Spiti <noreply@example.com>","reply_to":"support@example.com"}
 * secure=true -> implicit TLS (port 465); false -> STARTTLS (587).
 */
interface SmtpConfig {
  host: string; port: number; secure?: boolean;
  username?: string; password?: string; from: string; reply_to?: string;
}

interface Item {
  id: string; tenant_id: string; channel: "email" | "sms" | "push" | "portal";
  recipient: string; subject: string | null; body: string | null;
  payload: Record<string, any> | null; template_code: string | null;
}

let smtp: SmtpConfig | null | undefined;
async function smtpConfig(): Promise<SmtpConfig> {
  if (smtp === undefined) smtp = await getJsonSecret<SmtpConfig>("smtp_config");
  if (!smtp?.host || !smtp.from) {
    throw new PermanentError("vault secret 'smtp_config' missing or incomplete (host, from)", "smtp_not_configured");
  }
  return smtp;
}

/** {{key}} / {{a.b}} placeholders, values from payload.variables then payload. */
function render(text: string, payload: Record<string, any>): string {
  const vars = { ...payload, ...(payload.variables ?? {}) };
  return text.replace(/\{\{\s*([\w.]+)\s*\}\}/g, (_, path: string) => {
    const v = path.split(".").reduce<any>((o, k) => (o == null ? undefined : o[k]), vars);
    return v == null ? "" : String(v);
  });
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

async function sendEmail(it: Item) {
  if (!EMAIL_RE.test(it.recipient)) throw new PermanentError(`invalid recipient '${it.recipient}'`, "bad_recipient");
  const cfg = await smtpConfig();
  const payload = it.payload ?? {};
  const subject = render(it.subject ?? "(no subject)", payload);
  const text = render(it.body ?? "", payload);
  const html = typeof payload.html === "string" ? render(payload.html, payload) : undefined;

  const client = new SMTPClient({
    connection: {
      hostname: cfg.host,
      port: cfg.port ?? (cfg.secure ? 465 : 587),
      tls: !!cfg.secure,
      auth: cfg.username ? { username: cfg.username, password: cfg.password ?? "" } : undefined,
    },
  });
  try {
    await client.send({
      from: cfg.from,
      to: it.recipient,
      replyTo: cfg.reply_to,
      subject,
      content: text,
      html,
    });
  } catch (e) {
    const msg = (e as Error).message ?? String(e);
    // 5xx SMTP replies for the recipient are permanent; everything else retries.
    if (/\b55\d\b|\b5\.1\.1\b|user unknown|mailbox unavailable/i.test(msg)) {
      throw new PermanentError(`smtp rejected: ${msg}`, "smtp_rejected");
    }
    throw new RetryableError(`smtp error: ${msg}`, "smtp_error");
  } finally {
    try { await client.close(); } catch { /* ignore */ }
  }
}

async function deliver(it: Item) {
  switch (it.channel) {
    case "email":
      return await sendEmail(it);
    case "portal":
      return; // the notification_history row written on completion IS the portal inbox entry
    case "sms":
      throw new PermanentError("SMS channel is not configured (no SMS provider connected)", "sms_not_configured");
    case "push":
      throw new PermanentError("push channel is not configured", "push_not_configured");
    default:
      throw new PermanentError(`unknown channel '${it.channel}'`, "bad_channel");
  }
}

Deno.serve(async (req) => {
  const denied = requireServiceRole(req);
  if (denied) return denied;
  const limit = await readLimit(req, 25, 100);
  const sql = db();

  const items = await sql`select * from platform.claim_notification_batch(${limit})` as unknown as Item[];
  const tally = { sent: 0, retry: 0, failed: 0 };

  const skipped = await pool(items, 3, 90_000, async (it) => {
    try {
      await deliver(it);
      await sql`select platform.complete_notification_delivery(${it.id}, true, null)`;
      tally.sent++;
    } catch (e) {
      const info = errInfo(e);
      if (isPermanent(e)) {
        await sql`select platform.fail_notification_permanent(${it.id}, ${sql.json(info as any)})`;
        tally.failed++;
      } else {
        await sql`select platform.complete_notification_delivery(${it.id}, false, ${sql.json(info as any)})`;
        tally.retry++;
      }
    }
  });

  // Not started before the deadline: back to queued; the claim already counted an attempt.
  for (const it of skipped) {
    await sql`update public.notification_queue set status = 'queued', attempt_count = greatest(attempt_count - 1, 0)
              where id = ${it.id} and status = 'processing'`;
  }
  return json({ claimed: items.length, released: skipped.length, ...tally });
});
