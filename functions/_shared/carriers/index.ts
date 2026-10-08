import { acsCarrier } from "./acs.ts";
import type { CarrierAdapter } from "./types.ts";

/** keys: shipping_carriers.provider_code (lower-case) */
export const carriers: Record<string, CarrierAdapter> = {
  acs: acsCarrier,
  acs_courier: acsCarrier,
};
export * from "./types.ts";
