import { db } from "../_shared/db.ts";
import { AuthExpiredError, errInfo, isPermanent, PermanentError } from "../_shared/errors.ts";
import { json, pool, readLimit, requireServiceRole } from "../_shared/http.ts";
import { getAccessToken, loadIntegration } from "../_shared/tokens.ts";
import { adapters, type CommandInput, type DeviceContext } from "../_shared/devices/index.ts";

const WORKER = "edge-device-worker";

interface Cmd {
  id: string; tenant_id: string; device_id: string; command_type: string; payload: Record<string, any> | null;
}

async function runOne(c: Cmd) {
  const sql = db();
  try {
    const [map] = await sql`
      select dim.provider_code, dim.external_id, dim.config
      from public.device_integration_map dim
      where dim.device_id = ${c.device_id} and dim.tenant_id = ${c.tenant_id}
      limit 1`;
    if (!map) throw new PermanentError("device has no integration mapping", "no_mapping");

    const adapter = adapters[map.provider_code];
    if (!adapter) throw new PermanentError(`no adapter for provider '${map.provider_code}'`, "no_adapter");

    const integ = await loadIntegration(c.tenant_id, map.provider_code);
    const input: CommandInput = { id: c.id, type: c.command_type, payload: c.payload ?? {} };
    const mk = (token: string): DeviceContext => ({
      tenantId: c.tenant_id, deviceId: c.device_id, externalId: map.external_id,
      deviceConfig: map.config ?? {}, integ, token,
    });

    let result: Record<string, unknown>;
    let token = await getAccessToken(integ, { refresh: adapter.refresh });
    try {
      result = await adapter.execute(input, mk(token));
    } catch (e) {
      if (!(e instanceof AuthExpiredError)) throw e;
      token = await getAccessToken(integ, { force: true, refresh: adapter.refresh });
      result = await adapter.execute(input, mk(token));
    }

    await sql`select platform.complete_device_command(${c.id}, ${WORKER}, ${sql.json(result as any)})`;
    return "success";
  } catch (e) {
    const info = errInfo(e);
    const [r] = await sql`
      select platform.fail_device_command(${c.id}, ${WORKER}, ${sql.json(info as any)}, ${isPermanent(e)}) as outcome`;
    return String(r.outcome);
  }
}

Deno.serve(async (req) => {
  const denied = requireServiceRole(req);
  if (denied) return denied;
  const limit = await readLimit(req, 20, 100);

  const cmds = await db()`select * from platform.claim_device_commands(${limit}, ${WORKER})` as unknown as Cmd[];
  const tally: Record<string, number> = {};
  const skipped = await pool(cmds, 4, 90_000, async (c) => {
    const o = await runOne(c);
    tally[o] = (tally[o] ?? 0) + 1;
  });

  // Claimed but not started before the deadline: release for the next run.
  for (const c of skipped) {
    await db()`update platform.device_commands set status = 'queued', version = version + 1 where id = ${c.id} and status = 'processing'`;
  }
  return json({ claimed: cmds.length, released: skipped.length, outcomes: tally });
});
