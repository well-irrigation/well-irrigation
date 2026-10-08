import postgres from "npm:postgres@3.4.5";

type AutomationRequest = {
  well_id: string;
  chain_id: string;
  current_session_id: string;
  next_booking_id: string;
  decision_revision: number;
  automation_revision: number;
  policy_version: number;
  command_id: string;
  runtime_run_id: string;
};

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function equalSecret(provided: string, expected: string): boolean {
  const providedBytes = new TextEncoder().encode(provided);
  const expectedBytes = new TextEncoder().encode(expected);
  let difference = providedBytes.length ^ expectedBytes.length;
  const length = Math.max(providedBytes.length, expectedBytes.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (providedBytes[index] ?? 0) ^ (expectedBytes[index] ?? 0);
  }
  return difference === 0;
}

function readCredential(request: Request): string {
  const authorization = request.headers.get("authorization") ?? "";
  if (authorization.startsWith("Bearer ")) {
    return authorization.slice("Bearer ".length);
  }
  return request.headers.get("x-p2-automation-key") ?? "";
}

function hasForbiddenClientFields(body: Record<string, unknown>): boolean {
  return [
    "actor_kind",
    "actor_ref",
    "executor_id",
    "operator_profile_id",
    "tenant_id",
  ].some((field) => Object.prototype.hasOwnProperty.call(body, field));
}

function parseRequest(value: unknown): AutomationRequest | null {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  const body = value as Record<string, unknown>;
  const uuidFields = [
    "well_id",
    "chain_id",
    "current_session_id",
    "next_booking_id",
    "command_id",
    "runtime_run_id",
  ];
  if (hasForbiddenClientFields(body)) return null;
  if (uuidFields.some((field) => typeof body[field] !== "string" || !uuidPattern.test(body[field] as string))) {
    return null;
  }
  const revisionFields = [
    "decision_revision",
    "automation_revision",
    "policy_version",
  ];
  if (revisionFields.some((field) => !Number.isSafeInteger(body[field]) || (body[field] as number) < 0)) {
    return null;
  }
  return body as unknown as AutomationRequest;
}

Deno.serve(async (request: Request): Promise<Response> => {
  if (request.method !== "POST") {
    return json({ result: "rejected", failure_reason: "method_not_allowed" }, 405);
  }

  const expectedCredential = Deno.env.get("P2_AUTOMATION_CREDENTIAL") ?? "";
  if (!expectedCredential || !equalSecret(readCredential(request), expectedCredential)) {
    return json({ result: "rejected", failure_reason: "credential_rejected" }, 401);
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return json({ result: "rejected", failure_reason: "invalid_json" }, 400);
  }
  const input = parseRequest(body);
  if (!input) {
    return json({ result: "rejected", failure_reason: "invalid_automation_request" }, 400);
  }

  const dbUrl = Deno.env.get("SUPABASE_DB_URL") ?? "";
  const credentialRef = Deno.env.get("P2_AUTOMATION_CREDENTIAL_REF") ?? "p2-proof-v1";
  if (!dbUrl) {
    return json({ result: "rejected", failure_reason: "db_transport_unavailable" }, 503);
  }

  const sql = postgres(dbUrl, { max: 1, prepare: false });
  const attemptId = crypto.randomUUID();
  try {
    const result = await sql.begin(async (transaction) => {
      await transaction`set local role booking_automation_executor`;
      await transaction`
        select set_config(
          'well_irrigation.credential_ref',
          ${credentialRef},
          true
        )
      `;
      const rows = await transaction`
        select ops.execute_booking_transition_automation(
          ${input.well_id}::uuid,
          ${input.chain_id}::uuid,
          ${input.current_session_id}::uuid,
          ${input.next_booking_id}::uuid,
          ${input.decision_revision}::bigint,
          ${input.automation_revision}::bigint,
          ${input.policy_version}::bigint,
          ${input.command_id}::uuid,
          ${attemptId}::uuid,
          ${input.runtime_run_id}::uuid
        ) as result
      `;
      return rows[0]?.result ?? { result: "rejected", failure_reason: "empty_db_receipt" };
    });
    return json(result as Record<string, unknown>);
  } catch {
    return json({ result: "rejected", failure_reason: "internal_execution_rejected" }, 403);
  } finally {
    await sql.end({ timeout: 2 });
  }
});
