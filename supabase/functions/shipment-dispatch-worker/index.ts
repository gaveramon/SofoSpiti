import { db } from "../_shared/db.ts";
import { errInfo, isPermanent, PermanentError, RetryableError } from "../_shared/errors.ts";
import { json, pool, readLimit, requireServiceRole } from "../_shared/http.ts";
import { carriers, type Parcel, type Recipient } from "../_shared/carriers/index.ts";

const BUCKET = "shipping-labels";

interface Job {
  id: string; tenant_id: string; fulfilment_order_id: string;
  tracking_number: string | null; label_artifact_ref: string | null;
  payload: Record<string, any> | null;
}

/**
 * Recipient comes from payload.recipient (set by whoever calls
 * dispatch_fulfilment_order). fulfilment_orders has no address columns, so
 * the property address is only a fallback.
 */
async function resolveRecipient(job: Job): Promise<Recipient> {
  const sql = db();
  const p = job.payload ?? {};
  const r: Record<string, any> = { ...(p.recipient ?? {}) };

  if (!r.address || !r.zipcode || !r.city) {
    const propId = p.property_id;
    if (propId) {
      const [row] = await sql`select to_jsonb(pr) as j from public.properties pr where pr.id = ${propId}`;
      const j = (row?.j ?? {}) as Record<string, any>;
      r.address ??= j.address ?? j.address_line1 ?? j.street;
      r.address_number ??= j.address_number ?? j.street_number;
      r.zipcode ??= j.postal_code ?? j.zipcode ?? j.zip;
      r.city ??= j.city ?? j.locality;
      r.country ??= j.country_code ?? j.country;
    }
  }
  r.country ??= "GR";

  const missing = ["name", "phone", "address", "zipcode", "city"].filter((k) => !r[k]);
  if (missing.length) {
    throw new PermanentError(
      `recipient incomplete, missing: ${missing.join(", ")} (pass payload.recipient when dispatching)`,
      "recipient_incomplete",
    );
  }
  return r as Recipient;
}

async function carrierFor(job: Job): Promise<string> {
  const sql = db();
  const [r] = await sql`
    select sc.provider_code, fo.status
    from public.fulfilment_orders fo
    left join public.shipping_carriers sc on sc.id = coalesce(fo.carrier_id, ${job.payload?.carrier_id ?? null}::uuid)
    where fo.id = ${job.fulfilment_order_id}`;
  if (!r) throw new PermanentError("fulfilment order not found", "no_order");
  if (r.status === "cancelled") throw new PermanentError("fulfilment order is cancelled", "order_cancelled");
  if (!r.provider_code) throw new PermanentError("carrier has no provider_code", "no_carrier");
  return String(r.provider_code).toLowerCase();
}

async function uploadLabel(path: string, pdf: Uint8Array) {
  const base = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!base || !key) throw new Error("SUPABASE_URL / SERVICE_ROLE_KEY not set");
  const res = await fetch(`${base}/storage/v1/object/${BUCKET}/${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/pdf", "x-upsert": "true" },
    body: pdf,
  });
  if (!res.ok) {
    throw new RetryableError(`label upload failed HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`, "storage");
  }
  return `${BUCKET}/${path}`;
}

async function runOne(job: Job): Promise<string> {
  const sql = db();
  try {
    const code = await carrierFor(job);
    const carrier = carriers[code];
    if (!carrier) throw new PermanentError(`no carrier adapter for '${code}'`, "no_adapter");

    // 1. create the shipment, once. The voucher number is persisted straight
    //    away so a retry (or a crash) never creates a second voucher.
    let tracking = job.tracking_number;
    if (!tracking) {
      const recipient = await resolveRecipient(job);
      const parcel: Parcel = {
        weight_kg: Number(job.payload?.parcel?.weight_kg ?? 1),
        quantity: Number(job.payload?.parcel?.quantity ?? 1),
      };
      const out = await carrier.createShipment({
        reference: job.id, recipient, parcel, notes: job.payload?.notes,
      });
      tracking = out.tracking;
      await sql`update platform.shipment_dispatch_queue set tracking_number = ${tracking}, updated_at = now() where id = ${job.id}`;
    }

    // 2. label -> storage
    let labelRef = job.label_artifact_ref;
    if (!labelRef) {
      const pdf = await carrier.getLabelPdf(tracking);
      labelRef = await uploadLabel(`${job.tenant_id}/${job.id}.pdf`, pdf);
    }

    // 3. only now is the shipment really dispatched
    await sql`select platform.mark_shipment_dispatched(${job.id}, ${tracking}, ${labelRef})`;
    await sql`update public.fulfilment_orders set status = 'dispatched'::public.fulfilment_status
              where id = ${job.fulfilment_order_id} and status = 'ready_to_ship'::public.fulfilment_status`;
    return "dispatched";
  } catch (e) {
    const [r] = await sql`
      select platform.fail_shipment_dispatch(${job.id}, ${sql.json(errInfo(e) as any)}, ${isPermanent(e)}) as o`;
    return String(r.o);
  }
}

Deno.serve(async (req) => {
  const denied = requireServiceRole(req);
  if (denied) return denied;
  const limit = await readLimit(req, 10, 50);

  const jobs = await db()`select * from platform.claim_shipment_dispatch_batch(${limit})` as unknown as Job[];
  const tally: Record<string, number> = {};
  const skipped = await pool(jobs, 2, 90_000, async (j) => {
    const o = await runOne(j);
    tally[o] = (tally[o] ?? 0) + 1;
  });
  for (const j of skipped) {
    await db()`update platform.shipment_dispatch_queue set status = 'retrying', next_retry_at = now() where id = ${j.id} and status = 'processing'`;
  }
  return json({ claimed: jobs.length, released: skipped.length, outcomes: tally });
});
