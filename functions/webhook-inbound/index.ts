import { createHash } from "node:crypto";
import { db } from "../_shared/db.ts";
import { json } from "../_shared/http.ts";
import { aqaraInbound } from "../_shared/webhooks/aqara.ts";
import { asString, type InboundProvider, type JsonObject } from "../_shared/webhooks/types.ts";

/**
 * Generic inbound webhook endpoint.
 *   POST /functions/v1/webhook-inbound?provider=aqara     (default: aqara)
 *
 * This function only: verifies the provider signature, extracts identity
 * metadata, STORES the event (platform.ingest_external_webhook, idempotent) and
 * triggers processing. Device resolution + raw telemetry are done in Postgres by
 * platform.process_external_webhook -> public.process_integration_webhook, so
 * every provider takes the same path. The cron job `external_webhook_batch`
 * is the safety net for anything that fails here.
 *
 * Deploy WITHOUT JWT verification (providers cannot send a Supabase JWT):
 * the signature check is the authentication.
 */
const providers: Record<string, InboundProvider> = { aqara: aqaraInbound };

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ code: 405, message: "Method Not Allowed" }, 405);

  const provider = (new URL(req.url).searchParams.get("provider") ?? "aqara").toLowerCase();
  const adapter = providers[provider];
  if (!adapter) return json({ code: 404, message: "unknown provider" }, 404);

  const raw = await req.text();
  if (!(await adapter.verify(req, raw))) {
    return json({ code: 401, message: "Invalid provider webhook authentication" }, 401);
  }

  let payload: JsonObject;
  try {
    const b = JSON.parse(raw);
    if (!b || typeof b !== "object" || Array.isArray(b)) throw new Error();
    payload = b;
  } catch {
    return json({ code: 400, message: "Webhook payload must be a JSON object" }, 400);
  }

  const meta = adapter.parse(payload);
  // Stable fallback id (NOT a random uuid): a provider retry of the same body stays idempotent.
  const eventId = meta.externalEventId ?? `sha256:${createHash("sha256").update(raw).digest("hex")}`;
  const sql = db();

  // 1. store (idempotent on source + external_event_id)
  let webhookId: string;
  try {
    const [r] = await sql`
      select platform.ingest_external_webhook(
        ${meta.providerCode}, ${eventId}, ${meta.eventType}, ${sql.json(payload as any)}, null, ${meta.externalAccountId}
      ) as id`;
    webhookId = r.id as string;
  } catch (e) {
    console.error("webhook store failed", e);
    return json({ code: 500, message: "Internal server error" }, 500); // provider retries
  }

  // From here on the event is safely stored: always answer 200.
  const result: Record<string, unknown> = { webhook_id: webhookId, provider: meta.providerCode };
  try {
    const [wh] = await sql`
      select tenant_id, processing_status from platform.external_webhooks where id = ${webhookId}`;
    result.status = wh?.processing_status;

    if (wh?.processing_status !== "processed") {
      // 2. unknown provider device id? reconcile via the stable hardware id first.
      if (wh?.tenant_id && meta.externalDeviceId && adapter.resolveIdentity) {
        const [known] = await sql`
          select public.resolve_provider_device_by_external_id(${wh.tenant_id}, ${meta.providerCode}, ${meta.externalDeviceId}) as d`;
        if (!known?.d) {
          try {
            const id = await adapter.resolveIdentity(wh.tenant_id, meta.externalDeviceId);
            await sql`select public.resolve_or_reconcile_provider_device(${wh.tenant_id}, ${meta.providerCode}, ${id.externalId}, ${id.hardwareId})`;
            result.reconciled = true;
          } catch (e) {
            console.warn("device reconcile failed", (e as Error).message);
            result.reconciled = false;
          }
        }
      }
      // 3. process now (same function the cron job uses; row lock makes overlap safe)
      try {
        await sql`select platform.process_external_webhook(${webhookId})`;
        result.status = "processed";
      } catch (e) {
        // process_external_webhook already marked it failed and registered a retry task
        console.warn("webhook processing failed", (e as Error).message);
        result.status = "failed_will_retry";
      }
    }
  } catch (e) {
    console.error("post-store handling failed", e);
  }

  return json({ code: 0, message: "Success", result });
});
