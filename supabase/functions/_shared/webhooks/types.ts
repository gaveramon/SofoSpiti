export type JsonObject = Record<string, unknown>;

export interface WebhookMeta {
  providerCode: string;
  externalEventId: string | null; // null -> caller derives a stable id from the body
  eventType: string | null;
  externalAccountId: string | null;
  externalDeviceId: string | null;
}

export interface DeviceIdentity { externalId: string; hardwareId: string }

export interface InboundProvider {
  verify(req: Request, rawBody: string): Promise<boolean>;
  parse(payload: JsonObject): WebhookMeta;
  /** Optional: resolve stable hardware identity for a device id the DB does not know yet. */
  resolveIdentity?(tenantId: string, externalDeviceId: string): Promise<DeviceIdentity>;
}

export const asString = (v: unknown): string | null =>
  typeof v === "string" && v.trim() !== "" ? v.trim() : null;
