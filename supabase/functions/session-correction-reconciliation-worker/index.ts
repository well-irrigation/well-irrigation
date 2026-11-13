import postgres from "npm:postgres@3.4.5";

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function equalSecret(provided: string, expected: string): boolean {
  const a = new TextEncoder().encode(provided);
  const b = new TextEncoder().encode(expected);
  let difference = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    difference |= (a[i] ?? 0) ^ (b[i] ?? 0);
  }
  return difference === 0;
}

function setting(name: string, fallback: number, ceiling: number): number {
  const value = Deno.env.get(name);
  if (value === undefined) return fallback;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > ceiling) {
    throw new Error("invalid_worker_configuration");
  }
  return parsed;
}

Deno.serve(async (request: Request): Promise<Response> => {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const expected = Deno.env.get("F_RECON_WORKER_CREDENTIAL") ?? "";
  const authorization = request.headers.get("authorization") ?? "";
  const provided = authorization.startsWith("Bearer ")
    ? authorization.slice(7)
    : request.headers.get("x-f-recon-worker-key") ?? "";
  if (!expected || !equalSecret(provided, expected)) {
    return json({ error: "credential_rejected" }, 401);
  }
  // A wake is empty or {}. No business identifiers/options from the caller.
  try {
    const text = await request.text();
    if (text.trim()) {
      const body = JSON.parse(text);
      if (body === null || Array.isArray(body) || typeof body !== "object" || Object.keys(body).length) {
        return json({ error: "invalid_wake_request" }, 400);
      }
    }
  } catch {
    return json({ error: "invalid_wake_request" }, 400);
  }
  const dbUrl = Deno.env.get("SUPABASE_DB_URL") ?? "";
  if (!dbUrl) return json({ error: "db_transport_unavailable" }, 503);

  let batch: number, concurrency: number, visibility: number;
  try {
    // Initial safety defaults, configurable independently of business logic.
    batch = setting("F_RECON_LEASE_BATCH", 4, 100);
    concurrency = Math.min(batch, setting("F_RECON_CONCURRENCY", 2, 100));
    visibility = setting("F_RECON_VISIBILITY_SECONDS", 60, 3600);
  } catch {
    return json({ error: "invalid_worker_configuration" }, 503);
  }
  const sql = postgres(dbUrl, { max: concurrency, prepare: false });
  const metrics = { leased: 0, applied: 0, review: 0, pending: 0, completed: 0, invalid: 0, failed: 0 };
  try {
    // Commit the lease separately. Every process + archive has its own TX.
    const messages = await sql.begin(async (tx) => {
      await tx`set local role reconciliation_executor`;
      return await tx`
        select msg_id::text from billing.lease_session_correction_reconciliation_messages(${batch}, ${visibility})
      `;
    });
    metrics.leased = messages.length;
    let next = 0;
    await Promise.all(Array.from({ length: concurrency }, async () => {
      while (next < messages.length) {
        const message = messages[next++];
        try {
          const result = await sql.begin(async (tx) => {
            await tx`set local role reconciliation_executor`;
            await tx`set local timezone = 'UTC'`;
            await tx`select set_config('statement_timeout', ${`${Math.max(1, visibility - 5)}s`}, true)`;
            const rows = await tx`
              select billing.process_session_correction_reconciliation_message(${message.msg_id}::bigint) as result
            `;
            return rows[0]?.result;
          });
          switch (result?.status) {
            case "applied": metrics.applied++; break;
            case "financial_review_required": metrics.review++; break;
            case "pending": metrics.pending++; break;
            case "already_completed": metrics.completed++; break;
            case "invalid_message": metrics.invalid++; break;
            default: metrics.failed++;
          }
        } catch {
          // DB rollback preserves the leased message for redelivery after VT.
          // Do not emit SQL errors, credentials, or business payloads.
          metrics.failed++;
        }
      }
    }));
    return json(metrics);
  } catch {
    return json({ error: "lease_failed" }, 503);
  } finally {
    await sql.end({ timeout: 2 });
  }
});
