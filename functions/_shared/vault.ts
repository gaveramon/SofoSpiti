import { db } from "./db.ts";

export async function getSecret(name: string): Promise<string | null> {
  const [r] = await db()`select platform.get_vault_secret(${name}) as v`;
  return (r?.v as string | null) ?? null;
}

export async function getJsonSecret<T = Record<string, unknown>>(
  name: string,
): Promise<T | null> {
  const v = await getSecret(name);
  if (!v) return null;
  try { return JSON.parse(v) as T; } catch { return null; }
}

export async function upsertSecret(value: string, name: string, description: string) {
  await db()`select platform.upsert_vault_secret(${value}, ${name}, ${description})`;
}
