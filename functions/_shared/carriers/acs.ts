import { PermanentError, RetryableError } from "../errors.ts";
import { fetchChecked } from "../http.ts";
import { getJsonSecret } from "../vault.ts";
import type { CarrierAdapter } from "./types.ts";

/**
 * ACS Courier (Greece) web services.
 *
 * Vault secret `carrier_acs` (JSON):
 * {
 *  "base_url": "https://webservices.acscourier.net/ACSRestServices/api/ACSAutoRest",
 *  "api_key": "...", "company_id": "...", "company_password": "...",
 *  "user_id": "...", "user_password": "...",
 *  "sender": "Sofo Spiti", "language": "GR",
 *  "print_type": 2, "default_weight_kg": 1,
 *  "extra_create_params": { "Billing_Code": "...", "Charge_Type": 2 }
 * }
 *
 * NOTE: parameter names follow ACS' ACS_Create_Voucher / ACS_Print_Voucher
 * aliases. They could not be checked against ACS' documentation or a test
 * account while writing this: verify with ACS test credentials before going
 * live (see README, 'ACS test').
 */
interface AcsCfg {
  base_url?: string; api_key: string; company_id: string; company_password: string;
  user_id: string; user_password: string; sender?: string; language?: string;
  print_type?: number; default_weight_kg?: number; extra_create_params?: Record<string, unknown>;
}

const DEFAULT_URL = "https://webservices.acscourier.net/ACSRestServices/api/ACSAutoRest";

async function cfg(): Promise<AcsCfg> {
  const c = await getJsonSecret<AcsCfg>("carrier_acs");
  if (!c?.api_key || !c.company_id || !c.company_password || !c.user_id || !c.user_password) {
    throw new PermanentError("vault secret 'carrier_acs' missing or incomplete", "carrier_not_configured");
  }
  return c;
}

async function acs(c: AcsCfg, alias: string, params: Record<string, unknown>) {
  const res = await fetchChecked(c.base_url ?? DEFAULT_URL, {
    headers: { "Content-Type": "application/json; charset=utf-8", AcsApiKey: c.api_key },
    body: JSON.stringify({
      ACSAlias: alias,
      ACSInputParameters: {
        Company_ID: c.company_id, Company_Password: c.company_password,
        User_ID: c.user_id, User_Password: c.user_password,
        Language: c.language ?? "GR",
        ...params,
      },
    }),
    timeoutMs: 30000,
  });
  const j = await res.json();
  if (j?.ACSExecution_HasError) {
    const msg = String(j.ACSExecutionErrorMessage ?? "unknown ACS error").slice(0, 300);
    // credential problems will not fix themselves
    if (/password|user|company|api.?key|unauthor/i.test(msg)) throw new PermanentError(`ACS: ${msg}`, "acs_auth");
    throw new RetryableError(`ACS: ${msg}`, "acs_error");
  }
  return j;
}

function findPdfBase64(o: unknown): string | null {
  if (typeof o === "string") {
    const s = o.replace(/\s/g, "");
    return s.startsWith("JVBER") && s.length > 500 ? s : null; // "%PDF" in base64
  }
  if (Array.isArray(o)) { for (const x of o) { const r = findPdfBase64(x); if (r) return r; } }
  else if (o && typeof o === "object") { for (const x of Object.values(o)) { const r = findPdfBase64(x); if (r) return r; } }
  return null;
}

export const acsCarrier: CarrierAdapter = {
  async createShipment({ reference, recipient, parcel, notes }) {
    const c = await cfg();
    const today = new Date().toISOString().slice(0, 10);
    const j = await acs(c, "ACS_Create_Voucher", {
      Pickup_Date: today,
      Sender: c.sender ?? "Sofo Spiti",
      Recipient_Name: recipient.name,
      Recipient_Address: recipient.address,
      Recipient_Address_Number: recipient.address_number ?? "",
      Recipient_Zipcode: recipient.zipcode,
      Recipient_Region: recipient.city,
      Recipient_Phone: recipient.phone,
      Recipient_Cell_Phone: recipient.phone,
      Recipient_Email: recipient.email ?? "",
      Recipient_Country: recipient.country,
      Item_Quantity: parcel.quantity,
      Weight: parcel.weight_kg ?? c.default_weight_kg ?? 1,
      Delivery_Notes: notes ?? "",
      Reference_Key1: reference,
      ...(c.extra_create_params ?? {}),
    });
    const out = j?.ACSOutputResponse?.ACSValueOutput;
    const voucher = Array.isArray(out) ? out[0]?.Voucher_No : out?.Voucher_No;
    if (!voucher) throw new RetryableError("ACS returned no Voucher_No", "acs_no_voucher");
    return { tracking: String(voucher) };
  },

  async getLabelPdf(tracking) {
    const c = await cfg();
    const j = await acs(c, "ACS_Print_Voucher", {
      Voucher_No: tracking,
      Print_Type: c.print_type ?? 2,
      Start_Sticker: 1,
    });
    const b64 = findPdfBase64(j);
    if (!b64) throw new RetryableError("ACS print response contained no PDF", "acs_no_label");
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  },
};
