export interface Recipient {
  name: string; phone: string; email?: string;
  address: string; address_number?: string; zipcode: string; city: string; country: string;
}
export interface Parcel { weight_kg: number; quantity: number }

export interface CarrierAdapter {
  /** Create the shipment at the carrier. Must send `reference` so a duplicate can be traced. */
  createShipment(i: { reference: string; recipient: Recipient; parcel: Parcel; notes?: string }): Promise<{ tracking: string }>;
  /** Fetch the label PDF for an existing shipment. */
  getLabelPdf(tracking: string): Promise<Uint8Array>;
}
