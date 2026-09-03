// الطرف الخادمي لإعادة تعيين كلمة المرور بإثبات بشري (م-41F / هجرة 096).
//
// لماذا يوجد هذا الملف أصلًا: الاستعادة تحدث **قبل** تسجيل الدخول، وحدّ
// `anon EXECUTE = 0` في القاعدة مقيس بحرس دائم — فلا عقد في القاعدة يمكن
// أن يناديه من لا جلسة له. وجلسة المالك لا تستطيع تغيير كلمة مرور شخص آخر
// بالتصميم. فالخطوة الأخيرة وحدها هنا، بمفتاح الخدمة، وفي موضع واحد
// مُراجَع.
//
// ما يفعله بالضبط، ولا شيء غيره:
// 1. يتحقق من المدخلات شكلًا (رقم، رمز من ستة أرقام، كلمة مرور ≥ 6).
// 2. ينادي `api.consume_password_reset` (ممنوح لـ`service_role` وحده)
//    فتتحقق القاعدة من التذكرة وتخصم المحاولة أو تستهلكها.
// 3. عند `ok` وحدها: يطلب من نظام المصادقة تعيين كلمة المرور **التي
//    اختارها صاحب الحساب** (الثابت 706 — لا أحد يكتبها لأحد).
//
// وما لا يفعله: لا يسجّل الرمز ولا كلمة المرور في أي سجل، ولا يفشي إن كان
// الرقم مسجَّلًا: «لا تذكرة» جواب موحَّد لمن لا تذكرة له ولمن لا حساب له
// (الثابت 710).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

interface ResetBody {
  phone?: string;
  code?: string;
  new_password?: string;
}

const JSON_HEADERS = { 'Content-Type': 'application/json' };

function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

Deno.serve(async (request: Request) => {
  if (request.method !== 'POST') {
    return reply(405, { outcome: 'bad_request', reason: 'method' });
  }

  let body: ResetBody;
  try {
    body = await request.json();
  } catch {
    return reply(400, { outcome: 'bad_request', reason: 'json' });
  }

  const phone = (body.phone ?? '').trim();
  const code = (body.code ?? '').trim();
  const newPassword = body.new_password ?? '';

  if (phone.length < 9) {
    return reply(400, { outcome: 'bad_request', reason: 'phone' });
  }
  if (!/^[0-9]{6}$/.test(code)) {
    return reply(400, { outcome: 'bad_request', reason: 'code' });
  }
  if (newPassword.length < 6) {
    return reply(400, { outcome: 'weak_password', reason: 'length' });
  }

  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

  // مفتاح غائب = غير متاح صريح، لا محاولة صامتة تُعلن نجاحًا.
  if (!url || !serviceKey) {
    return reply(503, { outcome: 'unavailable', reason: 'service_key' });
  }

  const admin = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data, error } = await admin
    .schema('api')
    .rpc('consume_password_reset', { p_phone: phone, p_code: code });

  if (error) {
    console.error('consume_password_reset failed', error.code ?? error.message);
    return reply(503, { outcome: 'unavailable', reason: 'contract' });
  }

  const payload = (data ?? {}) as Record<string, unknown>;
  const outcome = String(payload.outcome ?? '');

  if (outcome === 'wrong_code') {
    return reply(200, {
      outcome: 'wrong_code',
      attempts_left: payload.attempts_left ?? null,
    });
  }

  if (outcome !== 'ok') {
    // «لا تذكرة» يشمل المنتهية والمُبطلة والمستهلكة: جواب واحد لا يفشي.
    return reply(200, { outcome: 'no_ticket' });
  }

  const profileId = String(payload.profile_id ?? '');
  if (profileId.length === 0) {
    console.error('contract returned ok without profile_id');
    return reply(503, { outcome: 'unavailable', reason: 'profile' });
  }

  const updated = await admin.auth.admin.updateUserById(profileId, {
    password: newPassword,
  });

  // التذكرة استُهلكت في القاعدة قبل هذه الخطوة. فشلها هنا حالة صريحة
  // تُقال للمستخدم: عليه أن يطلب رمزًا جديدًا من المالك، ولا نُعلن نجاحًا.
  if (updated.error) {
    console.error('updateUserById failed', updated.error.message);
    return reply(503, { outcome: 'ticket_spent_not_applied' });
  }

  return reply(200, { outcome: 'ok' });
});
