# Edge workers (Sofo Spiti, self-hosted Supabase)

| function | job (platform.scheduled_jobs) | doet |
|---|---|---|
| device-command-worker | device_command_batch (1 min) | TTLock / Shelly / Aqara commando's uit `platform.device_commands` |
| notification-worker | notification_batch (1 min) | e-mail via SMTP; portal = direct 'sent'; sms/push = duidelijke "not configured"-fout |
| shipment-dispatch-worker | shipment_dispatch_batch (5 min) | ACS Courier voucher + label (PDF naar Storage), pas daarna 'dispatched' |
| retry-task-worker | retry_task_batch (5 min) | `retry_tasks` met handler `http_request`/`webhook` |

Flow: pg_cron -> `platform.run_job` -> `platform.invoke_edge_function(only_if)` -> pg_net POST (Bearer service_role) -> worker claimt rijen via `platform.claim_*` (SKIP LOCKED) -> `complete_*` / `fail_*`.
De workers praten rechtstreeks met Postgres (`SUPABASE_DB_URL`); het platform-schema blijft dus buiten PostgREST.

## Deploy (self-hosted)
1. Draai de nieuwe `024_platform_bootstrap.sql` (bevat claim/fail-functies + seeds). Bestaande DB: zie "Activeren".
2. Zet de mappen in `volumes/functions/` van je Supabase docker-compose (`_shared`, en de vier worker-mappen). Herstart `functions` (edge-runtime) container.
3. Controleer dat de edge-runtime env `SUPABASE_DB_URL`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` heeft (standaard docker-compose: ja).
4. Storage bucket (private): `insert into storage.buckets (id,name,public) values ('shipping-labels','shipping-labels',false) on conflict do nothing;`
5. Vault-secrets (Studio > Vault of `select vault.create_secret(...)`):
   - `project_url`, `service_role_key` (bestaan al voor de scheduler; `project_url` moet vanuit de db-container bereikbaar zijn, bv. `http://kong:8000`)
   - `smtp_config` (JSON): `{"host":"…","port":587,"secure":false,"username":"…","password":"…","from":"Sofo Spiti <noreply@…>","reply_to":"…"}`  (secure=true = implicit TLS, poort 465)
   - `carrier_acs` (JSON): `{"api_key":"…","company_id":"…","company_password":"…","user_id":"…","user_password":"…","sender":"Sofo Spiti","print_type":2,"extra_create_params":{}}`
   - Aqara: `oauth_client_id_aqara` (AppID), `oauth_client_secret_aqara` (AppKey), `aqara_key_id`
   - TTLock: `oauth_client_id_ttlock`, `oauth_client_secret_ttlock`; Shelly: `oauth_client_id_shelly`, `oauth_client_secret_shelly` (bestaan al voor OAuth)
6. Provider-codes moeten kloppen met je seeds: `ttlock`, `shelly`, `aqara` in `integration_providers`/`device_integration_map`, en `shipping_carriers.provider_code = 'acs'` (of `acs_courier`).

## Activeren (bestaande database)
```sql
update platform.scheduled_jobs set is_active = true
 where job_name in ('device_command_batch','notification_batch','shipment_dispatch_batch','retry_task_batch');
select platform.sync_cron_schedules();
```
Nieuwe installatie: seeds staan al op actief. De job vuurt alleen als er werk is (`only_if`).

## Handmatig testen
```bash
curl -s -X POST "$SUPABASE_URL/functions/v1/notification-worker" \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H 'Content-Type: application/json' -d '{"limit":5}'
```
- Notificatie: `insert into notification_queue (tenant_id, channel, recipient, subject, body) values (<tenant>, 'email', 'jij@…', 'Test', 'Hallo {{naam}}');` (payload `{"variables":{"naam":"Ramon"}}`).
- Sms: rij blijft niet hangen, wordt 'failed' met `sms_not_configured`.
- Debug pg_net: `select id, status_code, content from net._http_response order by created desc limit 20;`

## Commando-vocabulaire (device_commands.command_type)
`lock`, `unlock`, `turn_on`, `turn_off`, `set_code`, `delete_code`, `set_resource` (alleen Aqara). Aliassen: create_code/add_code/generate_code, remove_code/revoke_code, on/off.
- `set_code` payload: `{code, start_at, end_at, name?}`; resultaat bevat TTLock `keyboardPwdId`. `delete_code` verwacht `{keyboardPwdId}` (of `code_id`): bewaar die id uit `device_commands.result` bij het aanmaken.
- TTLock: lock/unlock/codes. Shelly: turn_on/turn_off. Aqara: turn_on/turn_off standaard (resource 4.1.85); lock/codes alleen via `device_integration_map.config.resources.<type> = {resourceId,value}`.
- Onbekend/niet-ondersteund commando = direct DLQ (permanent), geen nutteloze retries.

## Zending
`dispatch_fulfilment_order(order_id, {recipient:{name,phone,email?,address,address_number?,zipcode,city,country}, parcel:{weight_kg,quantity}, notes?})`.
`fulfilment_orders` heeft zelf geen adreskolommen; zonder `payload.recipient` valt de worker terug op `properties` (address/city/postal_code) en faalt anders permanent met "recipient incomplete". Het ACS-voucher wordt direct opgeslagen (`tracking_number`) voordat het label wordt opgehaald, zodat een retry nooit een tweede voucher aanmaakt.

## ACS test (verplicht vóór live)
Parameternamen (`ACS_Create_Voucher`, `ACS_Print_Voucher`, `Voucher_No`, PDF-detectie) zijn geschreven zonder toegang tot ACS-documentatie of testaccount. Test met ACS testgegevens: maak één dispatch, check `platform.shipment_dispatch_queue.last_error` en pas `_shared/carriers/acs.ts` aan.

## Niet geverifieerd
Niets hiervan is uitgevoerd: geen Deno-runtime, geen Postgres, geen provideraccounts. Alleen syntax-check (TypeScript transpile) en dollar-quote/telling-check op de SQL.

## webhook-inbound (vervangt je bestaande Aqara-webhook function)
`POST /functions/v1/webhook-inbound?provider=aqara` (zonder JWT-verificatie deployen; de signatuur is de authenticatie).
Doet alleen: signatuur controleren -> `platform.ingest_external_webhook` (opslaan, idempotent) -> onbekend device-id? hardware-id (mac) ophalen en `resolve_or_reconcile_provider_device` -> `platform.process_external_webhook` (zelfde pad als cron-job `external_webhook_batch`, die vangt mislukte events op).
Nieuwe provider = één `InboundProvider` in `_shared/webhooks/` + regel in het register.
Vereist: rij in `platform.webhook_provider_tenant_map` (source `aqara`, external_account_id = Aqara `openId`, tenant_id), anders kan het tenant niet bepaald worden.
Wijzigingen t.o.v. de oude function: RPC-namen/signaturen kloppen nu met 000/006/007; fallback event-id is een hash van de body (geen random uuid); `queryAqaraDeviceDetail` ontbrak in de geüploade versie en is nu `query.device.info` (veldnamen `did`/`mac` ongetest).
