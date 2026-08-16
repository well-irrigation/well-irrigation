-- =====================================================================
-- 072 — ق-79: RPC-only writes
-- إلغاء الكتابة المباشرة من أدوار تطبيق العميل على الجداول الداخلية.
--
-- لا تسحب هذه الهجرة SELECT أو USAGE أو EXECUTE.
-- إجراءات الأعمال SECURITY DEFINER تستمر في تنفيذ الكتابات الداخلية
-- بصلاحيات مالكها، مع فحوص auth.uid() والأدوار الموجودة داخلها.
-- =====================================================================

revoke insert, update, delete, truncate, references, trigger
on all tables in schema
  core,
  iam,
  ops,
  billing,
  finance,
  inventory,
  audit,
  sync,
  reporting
from public, anon, authenticated;

-- حماية الجداول المستقبلية التي ينشئها postgres.
alter default privileges for role postgres
in schema
  core,
  iam,
  ops,
  billing,
  finance,
  inventory,
  audit,
  sync,
  reporting
revoke insert, update, delete, truncate, references, trigger
on tables
from public, anon, authenticated;
