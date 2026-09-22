import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

type JsonObject = Record<string, unknown>;

const jsonHeaders = { "content-type": "application/json; charset=utf-8" };

function response(status: number, body: JsonObject): Response {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactlyKeys(value: JsonObject, allowed: readonly string[]): boolean {
  const actual = Object.keys(value).sort();
  const expected = [...allowed].sort();
  return actual.length === expected.length &&
    actual.every((key, index) => key === expected[index]);
}

function diagnostic(error: unknown): JsonObject {
  if (!isObject(error)) return { kind: "unknown" };
  return {
    kind: typeof error.name === "string" ? error.name : "unknown",
    code: typeof error.code === "string" ? error.code : undefined,
    status: typeof error.status === "number" ? error.status : undefined,
  };
}

function trustedString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function isDefinitiveRpcError(error: unknown): boolean {
  return isObject(error) && typeof error.code === "string" &&
    error.code.length > 0;
}

Deno.serve(async (request: Request): Promise<Response> => {
  const correlationId = crypto.randomUUID();

  if (request.method !== "POST") {
    return response(405, { outcome: "method_not_allowed" });
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return response(400, { outcome: "invalid_json" });
  }

  if (!isObject(body) || typeof body.operation !== "string") {
    return response(400, { outcome: "invalid_request" });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("member-finalization config_missing", { correlationId });
    return response(503, { outcome: "service_unavailable", correlation_id: correlationId });
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  if (body.operation === "validate") {
    if (!hasExactlyKeys(body, ["operation", "phone", "code"]) ||
      typeof body.phone !== "string" || body.phone.length === 0 ||
      body.phone.length > 64 || typeof body.code !== "string" ||
      !/^[0-9]{6}$/.test(body.code)) {
      return response(400, { outcome: "invalid_request" });
    }

    const { data, error } = await admin.schema("api").rpc(
      "validate_member_finalization",
      { p_phone: body.phone, p_code: body.code },
    );

    if (error || !isObject(data) || typeof data.outcome !== "string") {
      console.error("member-finalization validate_failed", {
        correlationId,
        error: diagnostic(error),
      });
      return response(503, { outcome: "service_unavailable", correlation_id: correlationId });
    }

    if (data.outcome === "accepted_pending_owner" ||
      data.outcome === "owner_confirmed_pending_account") {
      const token = trustedString(data.continuation_token);
      const expiresAt = trustedString(data.continuation_expires_at);
      if (!token || !expiresAt) {
        console.error("member-finalization invalid_validate_contract", { correlationId });
        return response(503, {
          outcome: "service_unavailable",
          correlation_id: correlationId,
        });
      }
      return response(200, {
        outcome: data.outcome,
        continuation_token: token,
        continuation_expires_at: expiresAt,
      });
    }

    if (data.outcome === "wrong_code") {
      return response(200, {
        outcome: "wrong_code",
        attempts_left: typeof data.attempts_left === "number"
          ? data.attempts_left
          : 0,
      });
    }

    const safeOutcomes = new Set([
      "existing_account",
      "expired",
      "revoked",
      "no_invitation",
    ]);
    if (safeOutcomes.has(data.outcome)) {
      return response(200, { outcome: data.outcome });
    }

    console.error("member-finalization unknown_validate_outcome", { correlationId });
    return response(503, { outcome: "service_unavailable", correlation_id: correlationId });
  }

  if (body.operation !== "finalize") {
    return response(400, { outcome: "unsupported_operation" });
  }

  if (!hasExactlyKeys(body, ["operation", "continuation_token", "password"]) ||
    typeof body.continuation_token !== "string" ||
    !/^[0-9a-f]{64}$/i.test(body.continuation_token) ||
    typeof body.password !== "string" || body.password.length < 6 ||
    body.password.length > 256) {
    return response(400, { outcome: "invalid_request" });
  }

  const continuationToken = body.continuation_token;
  const password = body.password;
  const { data: preparation, error: preparationError } = await admin
    .schema("api")
    .rpc("prepare_member_finalization", {
      p_continuation_token: continuationToken,
    });

  if (preparationError || !isObject(preparation)) {
    console.error("member-finalization preparation_failed", {
      correlationId,
      error: diagnostic(preparationError),
    });
    return response(409, { outcome: "not_ready", correlation_id: correlationId });
  }

  if (preparation.outcome !== "ready") {
    const safeOutcome = preparation.outcome === "already_completed"
      ? "already_completed"
      : "not_ready";
    return response(409, { outcome: safeOutcome });
  }

  const normalizedPhone = trustedString(preparation.normalized_phone);
  const fullName = trustedString(preparation.full_name);
  const invitationId = trustedString(preparation.invitation_id);
  const tenantId = trustedString(preparation.tenant_id);
  const wellId = trustedString(preparation.well_id);
  const personId = trustedString(preparation.person_id);
  const role = trustedString(preparation.role);

  if (!normalizedPhone || !fullName || !invitationId || !tenantId ||
    !wellId || !personId || !role || !["operator", "partner"].includes(role)) {
    console.error("member-finalization invalid_prepare_contract", { correlationId });
    return response(503, { outcome: "service_unavailable", correlation_id: correlationId });
  }

  const email = `${normalizedPhone}@phone.wellirrigation.app`;
  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name: fullName, phone: normalizedPhone },
  });

  const createdUserId = created?.user?.id ?? null;
  if (createError || !createdUserId) {
    console.error("member-finalization auth_create_failed", {
      correlationId,
      error: diagnostic(createError),
    });
    return response(409, { outcome: "auth_creation_failed", correlation_id: correlationId });
  }

  let completionError: unknown = null;
  let completionDefinitivelyFailed = false;
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    let completion: unknown = null;
    completionDefinitivelyFailed = false;
    try {
      const result = await admin.schema("api").rpc("complete_member_finalization", {
        p_continuation_token: continuationToken,
        p_profile_id: createdUserId,
      });
      completion = result.data;
      completionError = result.error;
      completionDefinitivelyFailed = result.error
        ? isDefinitiveRpcError(result.error)
        : isObject(completion) && typeof completion.outcome === "string";
    } catch (error) {
      completionError = error;
    }

    const completionSucceeded = !completionError && isObject(completion) &&
      (completion.outcome === "confirmed" ||
        completion.outcome === "already_completed");

    if (completionSucceeded) {
      return response(200, { outcome: "confirmed" });
    }
  }

  if (!completionDefinitivelyFailed) {
    console.error("member-finalization completion_ambiguous", {
      correlationId,
      error: diagnostic(completionError),
    });
    return response(503, {
      outcome: "completion_ambiguous",
      correlation_id: correlationId,
    });
  }

  console.error("member-finalization db_completion_failed", {
    correlationId,
    error: diagnostic(completionError),
  });

  let deleteError: unknown = null;
  try {
    const result = await admin.auth.admin.deleteUser(createdUserId, false);
    deleteError = result.error;
  } catch (error) {
    deleteError = error;
  }

  if (deleteError) {
    console.error("member-finalization compensation_failed", {
      correlationId,
      error: diagnostic(deleteError),
    });
    return response(500, { outcome: "compensation_failed", correlation_id: correlationId });
  }

  return response(409, { outcome: "finalization_failed", correlation_id: correlationId });
});
