# القواعد الثابتة

**آخر تحديث:** 2026-08-18

قواعد **لا تُكسر أبدًا** في أي مكان من المشروع، مهما بدا ذلك منطقيًا في لحظة ما.
أي مخالفة تحتاج قرارًا مرقّمًا جديدًا في `DECISIONS.md`.

---

## الهوية والمفاتيح

1. كل معرّف أساسي من نوع **UUID**، وليس رقمًا متسلسلًا.
2. **لا حذف نهائي** لأي سجل مالي أو تشغيلي. الحذف منطقي فقط بعلم حالة.

## المال والوقت

3. المبالغ **أعداد صحيحة BIGINT**. ممنوع `float` أو `double` للمال مطلقًا.
4. وحدة المال = **ريال يمني كامل**. أصغر وحدة مالية مخزنة = 1 YER — ق-77.
5. الزمن يُحسب **بالثانية** ويُعرض ساعات:دقائق. ق-13.
6. **لا تقريب إطلاقًا** لا للوقت ولا للمال. ق-01 وق-12.
   * ملغى نهائيًا: قاعدة «التقريب للأعلى إلى 15 دقيقة» التي كانت في الأصل.
7. حساب قيمة الوقت يتم مرة واحدة من الثواني والسعر بالريال الكامل، دون تقريب:
   `amount_minor = (billable_seconds * hourly_rate_minor) / 3600`
8. لا توجد وحدة كسرية أصغر من الريال بعد ق-77؛ ناتج القسمة الصحيح هو المبلغ المالي المخزن.

## الوقود

9. الوقود يُسجّل **بالمللتر** كعدد صحيح.
10. **جالون محلي واحد = 20 لترًا** دائمًا.
11. **الكمية الفعلية هي المرجع** عند اختلافها مع المحسوبة نظريًا.
12. **لا يُنقل وقود من مزارع إلى آخر** في الحسابات.
13. الوقود **للرقابة والتكلفة فقط**، وليس للفوترة. ق-17.

## الوقت والتوقيت

14. كل طابع زمني من نوع **`timestamptz`**.
15. المنطقة الزمنية المعتمدة **`Asia/Aden`**.
16. يوم الجلسة للمحاسبة = **يوم النهاية**، والجلسة لا تُجزّأ. ق-27.
17. الجلسة غير المقفلة **لا تدخل في مجاميع أي يوم**. ق-37.
18. **لا إقفال تلقائي لأي جلسة إطلاقًا**. ق-40.

## النسب والشراكة

19. النسب تُخزّن **بمليون جزء** — 1,000,000 = 100%. ق-21.
20. **مجموع النسب = 100% حتمًا**، للملكية والأرباح. ق-03 وق-22.
21. بعد القسمة الصحيحة في توزيع الأرباح، **يذهب كامل باقي القسمة إلى صاحب أكبر حصة** — ق-77.
22. **حصص الشركاء تاريخية**؛ تغيّرها يقفل فترة ويفتح أخرى، **بلا أثر رجعي**. ق-23.

## المحاسبة

23. **الفاتورة ليست دفعة**؛ كيانان منفصلان تمامًا.
24. **توزيع الأرباح من النقد المحصل فعلًا**، وليس من المفوتر.
25. القيد **مزدوج الطرف** — double-entry.
26. **لا خصومات ارتجالية** في النسخة الأولى.
27. **لا تتغير حسابات الفترات المُقفلة** أبدًا.
28. السعر يُثبّت عند بداية الجلسة، و**لا يُعدّل بعد البدء**. ق-02 وق-20.

## العملة والعرض

29. **الريال اليمني فقط** في النسخة الأولى.
30. **الأرقام الإنجليزية 0-9 دائمًا** في العرض والإدخال.

## الأمان

31. **RLS مُفعّل بلا سياسات** في المرحلة الحالية — مقصود وليس خطأ.
32. **لا كلمات مرور ولا مفاتيح سرية داخل أي ملف** في المشروع. ق-44.

## البناء

33. أوامر التثبيت **واحدًا تلو الآخر**، مع إثبات نتيجة كل أمر قبل التالي.
34. **الإثبات لا الادعاء:** لا يُكتب «تم» إلا بعد فحص فعلي يُظهر النتيجة.

## ملحق توثيقي (2026-08-15): وحدة المال
بموجب ق-71 (المُعاد بناؤه من الادلة) وق-77: الوحدة الذرية للمال هي **الريال اليمني الكامل**؛ الاعمدة *_minor تعني ريالات صحيحة، واي ذكر لوحدة «اجزاء الالف (milli)» او *_milli في هذا الملف منسوخ منذ المرحلة 4. الكسور تُقتطع دائما لصالح الوحدة الكاملة (مثبت بالاختبار الدائم: 1.388 ← 1). توحيد توثيقي فقط بلا تغيير برمجي.

## حد Data API — ق-78

35. مخطط `api` هو عقد Data API الرسمي لتطبيق العميل.
36. مخططات `core` و`iam` و`ops` و`billing` و`finance` و`inventory` و`audit` و`sync` و`reporting` داخلية ولا تُعرض مباشرة لتطبيق العميل.
37. الجداول والتسلسلات الجديدة داخل `api` لا تحصل على وصول تلقائي لأدوار Data API؛ الوصول إليها Opt-in وبأقل صلاحية.
38. دوال PostgreSQL تحصل افتراضيًا على `EXECUTE` عبر `PUBLIC`؛ لذلك كل دالة جديدة داخل `api` يجب أن يتبع إنشاءها داخل المعاملة نفسها `REVOKE` صريح من `PUBLIC` والأدوار غير المسموحة، ثم `GRANT` للأدوار المطلوبة فقط.
39. اختبار القبول الدائم يجب أن يفشل إذا أصبحت أي دالة داخل `api` قابلة للتنفيذ من `anon`.
40. لا يستخدم `public` لأي منطق أعمال جديد خاص بالمشروع.
41. لا يُعد وجود RLS بديلًا عن Grants ولا يُعد وجود Grants بديلًا عن حد المخطط المكشوف.
42. أي تغيير في `Exposed Schemas` أو منح `api` يحتاج اختبار قبول يثبت حدود الوصول قبل اعتباره منفذًا.

## الكتابة عبر إجراءات الأعمال — ق-79

43. لا يملك `anon` أو `authenticated` Direct DML على جداول مخططات الأعمال الداخلية.
44. عمليات التطبيق الكتابية تمر عبر إجراءات أعمال معتمدة، لا عبر INSERT أو UPDATE أو DELETE من Flutter.
45. تبقى RLS طبقة عزل صفوف مستقلة، وليست مبررًا لمنح Direct DML.
46. لا تُعاد صلاحية كتابة مباشرة لجدول داخلي دون قرار صريح جديد.
47. الجداول الداخلية الجديدة يجب أن تبدأ بلا Direct DML لأدوار التطبيق، ويثبت ذلك اختبار قبول دائم.
48. سحب Direct DML لا يعني سحب SELECT أو USAGE أو EXECUTE تلقائيًا؛ كل طبقة صلاحيات تُراجع بحسب وظيفتها.

## دلالة أسماء الحقول المالية بعد ق-77

55. لاحقة `_minor` في أسماء الأعمدة والدوال **اسم تاريخي ثابت** ولا تعني جزءًا من الريال بعد ق-77.
56. لا يُعاد تفسير `_minor` كـmilli-riyal في Flutter أو التقارير أو API.
57. لا يسمى سلوك توزيع الباقي الحالي Largest Remainder Method؛ الوصف الدقيق هو «كل باقي القسمة لصاحب أكبر حصة».
58. لا يجوز لوثيقة مرجعية أقدم إعادة تفعيل قاعدة مالية نسخها ق-77.

## ق-80 — ثوابت هوية الأرض والمزارع

59. `iam.profiles` هو Login Identity وليس Farmer Field Identity.
60. `ops.farms.farmer_well_account_id` هو ارتباط المزارع المسؤول عن الأرض.
61. إذا كانت الأرض مرتبطة بحساب مزارع، فيجب أن يكون الحساب والبئر والأرض متطابقين.
62. Booking/Session لا يجوز أن يستخدم Farm مع Farmer Well Account مختلف.
63. المزارع الميداني لا يحتاج `auth.users` أو `iam.profiles`.

## ق-81 — ثوابت المضخة والطاقة والتوازي

64. `core.pumps` يمثل بيانات المعدة، وليس مصدر الطاقة الفعلي للجلسة.
65. `ops.session_segments.energy_source` هو مصدر الطاقة الرسمي للجلسة الحديثة.
66. `solar_seconds` و`diesel_seconds` يحسبان من `billable_seconds` للمقاطع الحديثة.
67. `well_diesel` و`farmer_diesel` يجمعان ضمن Diesel reporting.
68. `core.pumps.power_source` حقل Legacy فقط للجلسات `flat` التاريخية بلا مقاطع.
69. `ops.resource_concurrency_rules` هو مصدر قواعد التوازي.
70. أولوية التوازي: resource-specific ثم well-wide ثم default.
71. الافتراضي للمضخة = 1.
72. لا يضاف concurrency limit مكرر إلى `core.pumps`.


## ق-82 — ثوابت عقد القراءة الأولي

73. القراءة الأولية لسياق المستخدم والآبار تمر عبر
`api.app_bootstrap()` ولا تعتمد على قراءة Flutter المباشرة
لجداول الأعمال الداخلية.

74. هوية المستخدم داخل عقد التهيئة مشتقة من `auth.uid()`.

75. الآبار من `core.well_assignments` لا تظهر إلا من
التعيينات ذات الحالة `active`.

76. وصول الشريك الحالي يمكن أن يأتي من
`core.well_partners` النشط حتى دون سطر partner موازٍ
في `core.well_assignments`.

77. `iam.roles` و`iam.permissions` ليسا مصدر الصلاحية
التشغيلية حتى حسم م-18.

78. كل Read Contract جديد داخل `api` يجب أن يحافظ على
SECURITY INVOKER، وحجب `anon`، وعدم كشف المخططات الداخلية.

## ق-84 وق-88 — ثوابت الهوية والبحث ومنع التكرار

79. هاتف هوية التطبيق الفريد وفق ق-84 لا يمثل هويتين
مستقلتين في التطبيق.

80. لا تستنتج علاقة `iam.profiles` بـ`core.persons`
من تشابه الاسم؛ الربط يجب أن يكون صريحًا.

81. Smart Lookup لا ينشئ Master Data من مجرد نص البحث.

82. اختيار سجل موجود يعيد استخدام UUID ولا يعيد كتابة
نسخة جديدة من الاسم كهوية أعمال موازية.

83. منع التكرار الحتمي لا يعتمد على Flutter وحده.

84. كل كيان يسمح بالبحث والإنشاء يحتاج Entity Dedup
Profile قبل اعتباره مكتملًا.

85. Entity Dedup Profile يجب أن يحدد نطاق uniqueness
الصحيح؛ لا توجد قاعدة uniqueness عامة صالحة لكل الكيانات.

86. تطبيع العربية والهاتف الموجود يعاد استخدامه ولا
ينسخ كمنطق مستقل داخل Flutter.

87. Flutter لا ينفذ بحث أعمال مباشرًا على schemas
الداخلية؛ البحث الإنتاجي يمر عبر Read Contracts في `api`.

88. لا ينشأ Generic Search RPC يقبل اسم table أو schema
من العميل.

89. Disambiguation يعرض من العلاقات ولا يلوث الاسم
الأساسي للكيان ببيانات يمكن اشتقاقها.

90. الأرض المرتبطة بمزارع تستخدم
`ops.farms.farmer_well_account_id` ولا تنشأ علاقة
موازية لتسهيل UX.

91. نفس اسم الأرض لمزارعين مختلفين ليس duplicate حتميًا.

92. أرضان حقيقيتان بالاسم نفسه للمزارع نفسه تحتاجان
بيان تمييز حقيقي قبل السماح بتكرارهما.

93. Local search cache لا يصبح مصدر الحقيقة ولا يغير
هوية السجل؛ الدمج مع الخادم يكون بالـUUID.

94. عداد «المستحق حتى الآن» في Flutter عرض لحظي وليس
مصدر التسوية المالية النهائية.

95. Pause وResume وتغيير مصدر الطاقة يجب أن تستخدم
نموذج المقاطع الحالي ولا تبني عدادًا ماليًا موازيًا
لقواعد Backend.

96. إدخال دفعة عند بدء الجلسة لا يسمح بعملية جزئية
غامضة؛ يلزم atomic/idempotent server contract قبل
التنفيذ الإنتاجي.

97. أي تغيير قاعدة ناتج عن ق-84 أو ق-88 يبدأ في
Migration 078+؛ migrations 071–077 لا تعدل.

98. كل عقد بحث/إنشاء/تسعير جديد يحتاج اختبار قبول دائم
قبل وصف UX المعتمد بأنه منفذ.

## ق-89 — ثوابت Offline والمزامنة الخلفية

99. غياب الإنترنت لا يمنع بدء جلسة سقي.

100. كل عملية ميدانية Offline حرجة تحفظ Durable قبل
إظهار نجاح محلي.

101. كل Command Offline يحمل UUID ثابتًا لا يتغير
عند Retry.

102. لا يعتبر Local Success مساويًا لـServer Success.

103. لا يحذف Pending Command قبل Server ACK أو حسم
Conflict صريح.

104. أحداث الجلسة Offline تحفظ وترسل بترتيبها.

105. Retry لا يجوز أن يكرر أثرًا تشغيليًا أو ماليًا.

106. Flutter Offline لا يكسر ق-78/ق-79؛ المزامنة
تنتهي عبر `api.*`.

107. Background Sync لا يحتاج أن تكون واجهة التطبيق مفتوحة،
لكن توقيته يخضع لقيود Android.

108. لا يوثق ضمان «نفس الثانية» للمزامنة الخلفية.

109. Force Stop وRestricted mode استثناءان قد يمنعان
Background Work ويجب شرحهما للمستخدم.

110. لا تستخدم Foreground Service دائمًا لمجرد إبقاء
التطبيق حيًا.

111. أقل صلاحية لازمة هي القاعدة؛ لا تطلب صلاحيات
غير مرتبطة بوظيفة معتمدة.

112. Notification Permission مستقلة عن نجاح مزامنة البيانات.

113. عدم وجود Pricing Snapshot لا يمنع التشغيل Offline،
لكنه يمنع ادعاء مبلغ موثوق حتى حسم السعر.

114. السعر المؤجل يحسم حسب وقت الحدث الأصلي، لا وقت Sync.

115. اختلاف ساعة الجهاز المشبوه لا يصحح ماليًا بصمت.

116. الدفعة Offline تبقى Pending حتى قبول الخادم.

117. إنشاء المزارع/الأرض Offline يخضع لق-88 عند Sync.

118. Reboot أو Process Death لا يفقد Outbox.

119. كل تغيير DB ناتج عن ق-89 يبدأ من Migration 078+.

120. لا يعتبر ق-89 منفذًا قبل اختبارات Android الفعلية
للشبكة والبطارية وإعادة التشغيل والـRetry.

## ق-90 — ثوابت جاهزية الجهاز وشفافية المزامنة

121. Offline Readiness وBackground Sync Readiness
وNotification Readiness حالات مستقلة.

122. رفض الإشعارات لا يمنع Sync.

123. Background Restriction لا يمنع Local Offline Work.

124. لا يمنع التشغيل بسبب Pending Sync عادي.

125. لا يمنع التشغيل بسبب Battery Restriction وحده.

126. التشغيل يمنع إذا تعذر Durable Local Commit للعملية
الحرجة.

127. التشغيل يمنع إذا تعذر حفظ Stable Command ID للعملية.

128. كل Sync State يعرض للمستخدم بنص مفهوم، وليس اللون
وحده.

129. Manual Sync إجراء مساعد، وليس شرط تشغيل.

130. transient sync error يعاد تلقائيًا.

131. business conflict يحتاج Review ولا يعاد بلا نهاية.

132. Conflict لا يحذف Pending Command.

133. Notification Permission ليست شرطًا لحفظ أو مزامنة
بيانات الأعمال.

134. Device Readiness لا يطلب صلاحية غير مستخدمة فعليًا.

135. Manufacturer-specific guidance لا تعرض دون تحقق
واختبار موثق.

136. Force Stop لا يسمح بفقد Outbox أو Active Local Data.

137. Unknown critical readiness لا يسمى Ready.

138. أي دعم خادمي جديد لـSync Status يبقى عبر `api.*`.

139. أي DB change ناتج عن ق-90 يبدأ من Migration 078+.

140. ق-90 لا يعتبر منفذًا قبل Android integration
والاختبار الميداني.

## ق-91 — ثوابت الجلسة الجارية والفوترة

141. المزارع والأرض لا يعدلان مباشرة بعد بدء الجلسة.

142. العداد المالي الرئيسي يعتمد `billable_seconds`.

143. Pause time لا يدخل في billable time.

144. Pricing Pending لا يعرض كمبلغ صفر.

145. الدفع لا يغير قيمة accrued charge نفسها.

146. المبلغ الزائد على accrued يعرض كرصيد مقدم، لا
كمتبقي سالب.

147. دفعة Offline لا تصبح Server Posted قبل ACK.

148. Resume العادي يعيد مصدر وسعر التشغيل السابقين.

149. Resume بمصدر جديد لا ينشئ تشغيلًا وهميًا بالمصدر
القديم.

150. تغيير مصدر الطاقة يغير Segment ولا ينشئ Session جديدة.

151. ق-17 حاكم: Diesel Session Billing سعر ساعة شامل.

152. الوقود تكلفة/رقابة ولا يضاف Fuel Charge منفصل إلى
مستحق المزارع.

153. تنفيذ Migration 066 الذي يضم Fuel Charge إلى Session
Charge يعتبر Gap معروفة يجب تصحيحها في 078+.

154. Migration 066 لا تعدل بأثر رجعي.

155. إنهاء الجلسة أثناء Pause لا يحتاج Resume وهمي.

156. Local Completed لا يساوي Server Settled.

157. Business State وSync State مستقلان.

158. كل Active Session Command Offline له Stable Command ID.

159. Navigation أو إغلاق التطبيق لا ينهي الجلسة.

160. Active Session تستعاد من Durable State لا RAM.

161. Live amount وFinal charge وInvoice وFarmer balance
يجب أن تتبع السياسة المالية نفسها.

162. Flutter لا يستخدم float أو double لحساب المال.

163. أي تغيير DB ناتج عن ق-91 يبدأ من Migration 078+.

164. ق-91 لا يعتبر منفذًا قبل إغلاق م-26 باختبارات دائمة
واختبارات Android المطلوبة.

## ق-92 — ثوابت إنهاء الجلسة والتسوية

165. Local Completed لا يعني Server Settled.

166. لا يوصف مبلغ بأنه نهائي خادميًا قبل اكتمال التسوية.

167. كل جلسة سارية لها فاتورة سارية واحدة كحد أقصى.

168. إصدار الفاتورة بعد التسوية تلقائي ولا يحتاج زرًا
مستقلًا من المشغل.

169. Retry لا ينشئ Invoice ثانية.

170. Final Session Amount يجب أن يساوي Invoice Total.

171. Invoice Paid + Outstanding يجب أن يساوي Invoice Total.

172. دفعة سياق الجلسة تطبق على فاتورتها مرة واحدة فقط.

173. زيادة دفعة الجلسة تبقى Advance.

174. Advance قديم غير مرتبط لا يستهلك بصمت تلقائيًا.

175. Retry لا يكرر Payment Allocation.

176. Payment Pending لا يجوز أن يختفي من التسوية.

177. Fuel لا يضاف كرسوم منفصلة على المزارع وفق ق-17.

178. م-26 مانع لإنهاء Settlement implementation إنتاجيًا.

179. بعد Settlement لا تعدل حقائق الجلسة والفاتورة
مباشرة دون مسار تصحيح مدقق.

180. لا يوجد Reopen عادي لجلسة مسواة.

181. Settlement Result يأتي من Read/Write Contract موحد،
لا من تجميع Flutter لجداول داخلية.

182. Business Completion وSettlement/Sync State مستقلان.

183. كل Settlement Retry يستخدم Stable Command ID.

184. أي DB change ناتج عن ق-92 يبدأ من Migration 078+.

185. ق-92 لا يعتبر منفذًا قبل إغلاق م-27 واختبارات
Backend وAndroid المطلوبة.

## ق-93 — ثوابت التوثيق والاستئناف

186. معلومة حاكمة لا يجوز أن تبقى في المحادثة وحدها.

187. `DECISIONS.md` هو المصدر الأعلى للقرارات المرقمة.

188. `RESUME_POINT.md` هو المصدر الوحيد لنقطة التوقف.

189. `PROGRESS.md` لا يحتوي إلا على منجز مثبت بالدليل.

190. Planned وPending لا يوصفان كإنجاز في PROGRESS.

191. كل Gap حرجة تسجل في `OPEN_ISSUES.md`.

192. كل تغيير توثيقي جوهري يسجل في `DOC_CHANGELOG.md`.

193. Adopted وDocumented وImplemented وVerified حالات
مختلفة ولا يجوز دمجها.

194. أي AI جديد يتبع `AI_HANDOFF_PROTOCOL.md`.

195. ملفات التاريخ لا تتغلب على مصادر الحقيقة الحالية.

196. لا تنتقل دفعة معتمدة إلى التالية قبل حفظ توثيقها
في Git وفق Workflow المشروع.

197. عدم تشغيل اختبار يعني عدم تحديث Baseline أرقام
الاختبار.

198. README لا يكون مصدر Snapshot متغير؛ يحيل إلى
المصادر الحاكمة لتقليل Staleness.

199. كل تغيير في مصدر حقيقة أو ترتيب قراءة يحدث
`PROJECT_MAP.md`.

200. كل تغيير في نقطة العمل يحدث `RESUME_POINT.md`.

## ق-95 — ثوابت أسلوب التعاون

201. العربية هي لغة العمل الأساسية مع ترجمة المصطلحات
التقنية المهمة.

202. منهج القرار الموثق يعتمد الأدلة والبدائل والأسباب،
لا Chain of Thought داخلي.

203. لا توصية مشروع مهمة قبل تحديد مصدر الحقيقة الحالي.

204. «اعتمد» لا يحتاج إعادة تأكيد إذا كانت المقترحات محددة.

205. بعد إغلاق التوثيق ينتقل العمل مباشرة إلى التالي
عندما لا يوجد قرار جديد مطلوب من المالك.

206. UX discussion number لا يتحول إلى Q decision تلقائيًا.

207. كل تعارض مؤثر بين القرار والتنفيذ يصرح به ويسجل
إذا لم يحل.

208. لا Verified دون دليل.

209. Terminal Output يقرأ حسب أول Failure وآخر Success.

210. ق-94 يقلل عدد النقاشات ولا يقلل نطاق التغطية.

## ق-96 — ثوابت أوامر الطرفية

211. كل أمر تنفيذي يسبقه شرح الوضع والتغيير والسبب.

212. الدفعة الكاملة تعرض في Bash Block خارجية واحدة.

213. لا Nested Triple Backticks داخل Command Block.

214. Base64 ليس أسلوب التسليم الافتراضي.

215. `set -e` داخل Subshell فقط.

216. الدفعات المعتمدة على Commit تستخدم Expected HEAD Guard.

217. دفعات الكتابة الجديدة تبدأ من Clean Worktree إلا
إذا كانت Recovery.

218. Content checks يجب أن تتحمل Whitespace وLine Wrap.

219. لا تعاد خطوة Write إذا نجحت وثبتت ثم فشل Validation.

220. Commit ناجح مع Push فاشل يستأنف من Push ولا ينشئ
Commit جديدًا.

221. Project tests وDB reset وDocker verification ينفذها
المالك.

222. نجاح كتابة الملفات وحده لا يغلق دفعة Git.

223. Git closure يتطلب Commit وPush وClean Worktree عند
كونها أهداف الدفعة.

224. UTF-8 وFinal Newline ثابتان في وثائق النص.

225. Recovery يكون من أصغر نقطة آمنة بعد الفشل.

## ق-97 — ثوابت بوابة التوثيق

226. لا انتقال من موضوع معتمد إلى التالي قبل
`DOCUMENTATION_GATE=PASS`.

227. القرار المهم يجب أن يحفظ السبب اللازم لفهمه مستقبلًا.

228. Reasoning Record القابل للمراجعة يحفظ الأدلة
والافتراضات والبدائل المهمة والمخاطر والاستنتاج،
ولا يعتمد على Chain of Thought داخلية.

229. كل Gap مؤثرة غير منفذة تسجل في `OPEN_ISSUES.md`.

230. كل ادعاء Verified أو Closed يحتاج دليلًا.

231. عدم تشغيل اختبار يمنع تحديث Baseline الخاص به.

232. قواعد التوثيق نفسها تخضع لبوابة التوثيق.

233. Traceability يجب أن تصل القرار بالتنفيذ والاختبار.

234. PROGRESS لا يسجل إلا المنجز المثبت.

235. DOC_CHANGELOG يسجل كل دفعة توثيق جوهرية.

236. RESUME_POINT يجب أن يكون محدثًا قبل الانتقال.

237. Git closure جزء من اكتمال دفعة التوثيق.

238. تكرار النص بين الملفات ليس شرط شمول؛ المصدر الحاكم
يحمل التفاصيل والبقية تسجل دورها المناسب.

239. فشل Documentation Gate يبقي العمل في الموضوع الحالي.

240. ق-97 يكمل ق-93 وق-95 وق-96 ولا ينسخها.

## ق-98 — ثوابت سجلات التشغيل والحجوزات والتسليم

241. تعطيل كيان لا يمحو ظهوره من السجل التاريخي.

242. Closed Session لا تعدل مباشرة.

243. Smart Lookup في UX-13 يعيد استخدام ق-88.

244. Farm تتبع Farmer Well Account وفق ق-80.

245. Hard Delete ليس مسار UX عاديًا لكيان له تاريخ.

246. Booking محفوظ Offline لا يعني Booking مؤكدة.

247. Backend هو السلطة النهائية لتعارض الموارد.

248. Business Booking State وSync State مستقلان.

249. Retry لا ينشئ Booking مكررًا.

250. Retry لا ينشئ Resource Reservation مكررة.

251. Booking mutation/history/reservation يجب أن تكون
متسقة ذريًا أو بضمانات مكافئة.

252. Session Start من Booking يحتاج فعلًا صريحًا.

253. حلول الموعد لا يبدأ Session تلقائيًا.

254. لا Normal Close Shift مع Active Session غير محسومة.

255. اختيار المشغل المستلم لا ينقل المسؤولية وحده.

256. Session Responsibility Transfer يحتاج Receiver Acceptance.

257. Rejected Transfer يبقي المسؤولية على المرسل.

258. Operational Transfer لا يساوي Cash Handover.

259. Cash Handover الحالي وتأكيد المالك لا يستخدمان كبديل
لقبول المسؤولية التشغيلية.

260. Owner open-session close bypass الحالي لا يدخل Flutter
العادي وفق ق-98.

261. أي إصلاح لهذا التعارض يبدأ من Migration 078+.

262. Flutter لا يجمع السجل التشغيلي من الجداول الداخلية
مباشرة إذا كان يلزم Read Model موحد.

263. كل Write جديد يمر عبر `api.*`.

264. Offline shift/transfer actions تحتاج Stable Command IDs.

265. UX-13 لا تعتبر Production Complete قبل إغلاق م-28.

266. لا تتغير أرقام Baseline التقنية دون اختبار جديد.

## ق-99 — ثوابت المال والشركاء والتصحيحات

267. Farmer debt وFarmer advance حقيقتان منفصلتان.

268. لا Silent Netting بين الدين والرصيد المقدم.

269. Existing old advance لا يستهلك دون Allocation صريحة.

270. General payment allocation يعرض قبل التأكيد.

271. Oldest-invoice ordering اقتراح افتراضي لا تسوية صامتة.

272. Overpayment غير المخصص يبقى Advance.

273. Canonical Receipt لا يعد نهائيًا قبل Server ACK.

274. Offline Payment لا توصف Posted قبل المزامنة الناجحة.

275. Payment retry لا يجوز أن ينشئ تحصيلًا مكررًا.

276. Unknown financial delivery تحتاج Reconciliation أولًا.

277. Posted Invoice/Payment لا تعدل مباشرة.

278. Expense attachment skip يحفظ سببه عند تطبيق التخطي.

279. Pending Approval Expense لا تعامل كPosted نهائية.

280. Partner-paid expense لا تعامل كCashbox expense.

281. Ownership Percentage وProfit Percentage مستقلتان.

282. Share changes تحفظ كتاريخ فعال ولا تعيد كتابة الماضي.

283. Distribution line تحفظ Profit Percentage Snapshot.

284. تغيير النسب مستقبلًا لا يعيد حساب Distribution قديمة.

285. Profit calculation لا يساوي Profit approval.

286. Approved distribution amounts لا تعدل مباشرة.

287. Partner receivable لا يحتسب في أكثر من دورة.

288. Partner irrigation deduction لا يخصم في أكثر من دورة.

289. Partial partner payout يحفظ paid وremaining.

290. Partner لا يرى Financial Details خاصة بشريك آخر عبر API.

291. Distribution final actions Online only.

292. Closed Accounting Period لا تقبل Posting عاديًا.

293. Reopen Period مسار مدقق وليس Toggle مباشرًا.

294. Posted Financial Correction تستخدم Reversal/Adjustment
وليس Direct Edit.

295. Flutter لا تنفذ Accounting Engine موازية.

296. Flutter لا تنفذ Rounding مالي مستقل.

297. Maintenance Reserve `round()` الحالي يحتاج Audit
قبل Production.

298. Backend هو Authority للمال والتواريخ النهائية.

299. أي DB fix جديد يبدأ من Migration 078+.

300. UX-14 لا تعتبر Production Complete قبل إغلاق م-29.

301. عدم تشغيل اختبارات جديدة لا يغير Baseline المثبت.

## ق-100 — ثوابت إدارة البئر والتقارير والرسوم

302. Well مستخدم تاريخيًا لا Hard Delete من Flutter.

303. لا Unsafe Well/Pump transition مع Active Session.

304. Pump هي Equipment وليست Session Energy Authority.

305. Modern Energy Source = Session Segment.

306. Pump Power Source Legacy fallback فقط.

307. Maintenance/Retired Pump لا تستخدم عاديًا لعمل جديد.

308. Well Fuel وFarmer Fuel لا يدمجان.

309. Estimated Fuel Measurement لا توصف Actual.

310. Fuel Physical Difference لا يخفى.

311. Fuel Balance لا يعدل مباشرة لتسوية الفرق.

312. Fuel Adjustment يحتاج Audit.

313. Fuel لا يضاف Farmer Surcharge فوق Inclusive Hourly.

314. Price changes تحفظ تاريخيًا.

315. Historical Session لا يعاد تسعيرها بسعر مستقبلي.

316. V1 Diesel Pricing = Inclusive Hourly.

317. `operation_plus_fuel` لا يظهر في Flutter V1.

318. لا Minimum Billable Minutes.

319. Untrusted Offline Price = Pricing Pending.

320. Report Totals تأتي من Backend Canonical Read Models.

321. Report Drill-down يجب أن يطابق الرقم المصدر.

322. Closed Session daily attribution تتبع End Day rule.

323. Cached Report لا توصف Live.

324. V1 Chart هي Presentation وليست Source of Truth.

325. V1 Chart Types = Bar + Line فقط.

326. لا Chart في Owner Home في V1.

327. Reports Main تعرض Primary Chart واحدة في الوقت.

328. Irrigation Chart تستخدم Daily Billable Hours.

329. Financial Chart لا تخلط وحدات مختلفة في محور واحد.

330. Energy Chart الحديثة تستخدم Session Segments.

331. Fuel Mini Chart تعرض Consumption لا Farmer Billing.

332. Partner Chart لا تسرب بيانات شريك آخر.

333. Tap على Chart Element يعرض Exact Value.

334. Chart Drill-down يخضع للصلاحية.

335. Stale Chart تعرض Last Sync/As-of.

336. Chart لا تعتمد على اللون وحده.

337. Flutter لا تقوم Reporting Business Aggregation.

338. Empty Report لا ينتج Fake Zero Chart.

339. Server aggregation تستخدم لتجنب تحميل Raw Rows بلا حاجة.

340. Reporting Timezone/Day Boundary يجب أن يكون صريحًا.

341. Report API يخضع لنفس Role Authorization.

342. أي DB change جديد يبدأ من Migration 078+.

343. UX-15 لا تعتبر Production Complete قبل إغلاق م-30.

344. عدم تشغيل اختبارات جديدة لا يغير Baseline المثبت.

## ق-101 — ثوابت الحساب والإعدادات

345. UX-16A لا تشمل Platform Administration.

346. Phone واحد لا ينشئ أكثر من Canonical Person.

347. Phone Change ليست Direct Edit.

348. Phone Change النهائية Online وموثوقة.

349. Lost-phone recovery لا تعتمد على Name Guessing.

350. Forgot Password في V1 يستخدم Verified Recovery.

351. Well Role لا ينشئ Account جديدًا للشخص نفسه.

352. Role Catalog ليس Authorization وحده.

353. Operator deactivation لا تترك Active Responsibility.

354. Removing Partner Access لا يمحو Partnership History.

355. App Notification Preference تختلف عن Android Permission.

356. Notification denial لا يمنع Offline Work.

357. Local Private Data هي Account-scoped.

358. Logout لا يمحو Pending Business Commands.

359. Account B لا يرى Local Private Data للحساب A.

360. Returning Account A يستطيع استعادة Pending State التابعة له.

361. Local Wipe لا يدمر Pending State بصمت.

362. V1 UI عربية RTL.

363. Digits المعروضة English دائمًا.

364. User-facing Date/Time formatting إنجليزي ثابت.

365. Backend Time Semantics لا تحددها Formatter Flutter.

366. Platform Admin Password Requirement لا يحكمها ق-101.

367. Any new DB change يبدأ من Migration 078+.

368. UX-16A لا تعتبر Production Complete قبل إغلاق م-31.

## ق-102 — ثوابت إدارة المنصة

369. Platform Admin ليس Well Owner.

370. Platform Admin ليس Operator أو Partner أو Farmer تلقائيًا.

371. Platform Authority مستقلة عن Well Role Assignments.

372. Admin لا يحتاج Impersonation لإدارة البئر.

373. Admin Mutation تسجل Platform Admin كActor.

374. Platform Admin Console مستقلة عن Owner Home.

375. Platform Admin Console Web/Desktop-first في V1.

376. RTL Desktop Sidebar الأساسية على اليمين.

377. Admin Dashboard تبدأ بـNumeric KPIs.

378. Dashboard تغطي Wells/Accounts/Operations/Sync/Activation/Finance.

379. Dashboard Metrics تأتي Server Aggregated.

380. Admin Dashboard تتحدث تلقائيًا عند توفر الاتصال.

381. Near-real-time لا تعني ضمان 0ms.

382. Stale Admin Data تعرض Last Update.

383. KPI يدعم Drill-down عند وجود Source Records.

384. Admin V1 Charts = Bar + Line.

385. KPIs تسبق Charts بصريًا.

386. Admin Charts لا تعتمد على اللون وحده.

387. Platform Admin Global Business Authority لا تنشئ Owner Membership.

388. Privileged Backend Secrets لا توضع في Admin Client.

389. Cross-Tenant Admin Write تمر عبر Trusted Backend.

390. Admin API Authorization مستقل عن Tenant Role Authorization.

391. Admin actions الحساسة Audit mandatory.

392. Admin correction يجب ألا يكسر Domain Historical Invariants.

393. Platform Admin يرى Server-observable Sync Truth فقط.

394. Offline-only device command لا يدعي Server أنه رآه.

395. Password Visibility Requirement معتمد كهدف منتج.

396. Password Visibility Requirement غير Implemented حاليًا.

397. Plaintext Password Store ممنوع؛ ق-103 تعتمد Vault مشفرة فقط.

398. Recoverable Encrypted Password Vault معتمدة بق-103؛ التنفيذ Pending.

399. Infrastructure Secrets ليست Ordinary Platform Data في UI.

400. PA-01 لا تعتبر Production Complete قبل إغلاق م-32.

401. Any DB change جديد يبدأ من Migration 078+.

## ق-103 — ثوابت الحسابات والآبار والدعم وكلمات المرور

402. Platform Admin يستطيع إدارة أي Account عبر Admin Contracts.

403. Platform Admin يستطيع إدارة أي Well دون Owner Role.

404. Global Search لا ينشئ Identity Relationship بالتخمين.

405. Name Similarity لا يكفي للMerge.

406. Identity Merge يحتاج Canonical Target واضحًا.

407. Merge لا يمحو Financial/Operational History.

408. Account Suspension لا يمحو التاريخ.

409. Well Suspension لا يمحو التاريخ.

410. Active Session لا تنهى بصمت عند Suspend Well.

411. Admin Preview للمستخدم Read-only.

412. Admin Full Authority لا تعني Direct Historical Rewrite.

413. Posted Financial Record يصحح عبر Correction/Reversal.

414. Admin Support Cases لها Timeline ومراجع ثابتة.

415. Support Notes لا تحتوي Infrastructure Secrets.

416. Error Reference قابلة للبحث إداريًا.

417. Admin Audit Append-only.

418–443. ثوابت Password Vault السابقة من ق-103
منسوخة في جانب Password Vault بق-105.

القواعد الحالية تبدأ في قسم ق-105 أدناه.

444. أي DB change جديد يبدأ من Migration 078+.

445. PA-02 لا تعتبر Production Complete قبل إغلاق م-33.

## ق-104 — ثوابت البحث والمعايير وإدارة المنصة

446. القرار الجوهري المنطبق عليه البحث يمر بـResearch & Standards Gate.

447. Project Source of Truth يقرأ قبل External Guidance.

448. Official Standard أعلى من Forum feedback عند التعارض العادي.

449. User Feedback مصدر Experience وليس Security Authority.

450. Exception لا توصف Best Practice.

451. إذا فوض المالك اختيار الأفضل، يختار AI الحل الأعلى
معياريًا وملاءمة وفق ق-104 دون سؤال شكلي.

452. Admin Dashboard KPIs تسبق Charts.

453. كل Admin Chart يجب أن تجيب عن سؤال واضح.

454. Large Admin Tables تستخدم Server-side Pagination.

455. Infinite Scroll ليس نمط Admin Tables الأساسي في V1.

456. Long Admin pages تحافظ على Search/critical filters سهلة الوصول.

457. Near-real-time لا يعني blind high-frequency polling.

458. Monitoring تعرض Symptom قبل Cause في الواجهة التشغيلية.

459. Admin Web تستهدف WCAG 2.2 AA.

460. Critical Admin Controls تستهدف interaction area كبيرة
تقريبًا 44×44 CSS px عندما يسمح التصميم.

461. Keyboard Focus لا يخفى خلف Sticky UI.

462. Dynamic Status لا يعتمد على اللون وحده.

463. Platform Admin MFA إلزامية قبل Production.

464. High-risk admin actions تحتاج Step-up عندما تحددها السياسة.

465. Privileged Admin Actions تدخل Audit.

466. Passwords/Tokens/Keys لا تدخل Logs.

## ق-105 — ثوابت كلمات المرور الحالية

467. ق-105 تنسخ Option B الخاصة بكلمات المرور من ق-103.

468. لا Recoverable Password Vault.

469. لا Current Password Reveal لمسؤول المنصة.

470. لا Old Password Reveal.

471. Password Verifier يبقى One-way Auth Hash.

472. Platform Admin يستطيع Force Password Reset لا Reveal.

473. Password الجديدة يختارها المستخدم بعد Identity Verification.

474. Platform Admin لا يرى Password الجديدة.

475. Password Recovery يحتاج Verified Phone OTP.

476. Lost-phone recovery يحل Identity/Phone أولًا.

477. No Password Reveal bypass لـIdentity Recovery.

478. Admin-triggered security reset يمكن أن يبطل Sessions
وفق العقد الأمني.

479. Password minimum target في V1 = 15 characters.

480. Long passphrases مسموحة ومفضلة.

481. Spaces وUnicode مسموحة.

482. لا Composition Rules إلزامية من نوع uppercase+digit+symbol.

483. لا Periodic Password Rotation بلا Risk/Compromise.

484. Common/Compromised Password blocking مطلوب قبل
Production عندما تنفذ capability.

485. Password لا تدخل Audit.

486. Password لا تدخل Logs.

487. Password لا تدخل Analytics.

488. Password لا تدخل Local DB.

489. Password لا تدخل Sync Outbox.

490. Password Recovery Online-only.

491. Platform Admin Auth Admin operations Trusted Backend only.

492. Elevated Supabase Secret لا تدخل Browser/Flutter.

493. Significant High-risk Transaction Data إذا تغيرت
بعد Confirmation تبطل Authorization السابق.

494. PA-02 لا تعتبر Production Complete قبل إغلاق م-33
وفق ق-105 الحالية.

495. أي DB change جديد يبدأ من Migration 078+.

## ق-106 — ثوابت مبيعات المنصة والتفعيل والتحكم الإداري

496. Platform Commerce وWell Finance مجالان منفصلان.

497. V1 بيع دائم يدوي وليست مجانية بالكامل.

498. V1 لا تستخدم Subscription دورية.

499. كل Purchased Well تحتاج Entitlement مستقلة.

500. Sale واحدة يمكن أن تنتج عدة Entitlements.

501. Sale + Entitlement Grant يجب أن تكون Atomic.

502. Sensitive Admin Commands يجب أن تكون Idempotent.

503. Retry لا ينشئ Sale مكررة.

504. Retry لا ينشئ Entitlement إضافية.

505. OTP لا تستهلك Entitlement.

506. Account Creation لا تستهلك Entitlement.

507. Well Creation الناجحة هي نقطة الاستهلاك.

508. Well + Entitlement Consumption Atomic.

509. Entitlement واحدة لا تستهلك لبئرين.

510. Consumed Entitlement تتبع Well.

511. Ownership Transfer لا يحرر Entitlement.

512. Sale الأصلية لا Hard Delete عند التصحيح.

513. Consumed Entitlement لا تعاد Available بتعديل مباشر.

514. Replacement Entitlement لها Identifier جديد.

515. Available Revocation تحتاج Reason + Confirmation + Audit.

516. High-risk Revocation تحتاج Step-up.

517. Consumed Revocation ليست Toggle عادية.

518. Revocation لا تحذف Well History.

519. Admin monitoring لا تدعي معرفة Offline-only Commands.

520. No recent server update لا يساوي Stuck تلقائيًا.

521. لا Generic Edit Session.

522. لا Raw SQL Business Editor في PA V1.

523. لا Fake Remote Pump Control.

524. Administrative Closure تحفظ Timeline.

525. Global Finance Monitoring = Read-first.

526. Posted Payment لا Direct Edit.

527. Posted Expense لا Direct Edit.

528. Approved Distribution لا Direct Edit.

529. Financial Correction تتبع ق-99.

530. لا Force Reopen bypass في V1.

531. Sensitive Confirmation تعرض Significant Data.

532. Changed Significant Data invalidates old confirmation.

533. Every sensitive PA-03 mutation is audited.

534. Audit لا تخزن Password/Token/Key.

535. Sensitive Export audited.

536. Export تحترم Filters.

537. Large Admin Tables = Server-side pagination/filter/sort.

538. Infinite Scroll ليست Admin Table pattern الأساسية.

539. Final Success يحتاج Server ACK.

540. Retry uses same Stable Operation ID.

541. Unknown result reconciles before new command.

542. PA-03 privileged writes Online-only.

543. Privileged Admin writes لا تدخل Offline Outbox.

544. Client لا يحمل service_role أو privileged secret.

545. ق-106 تنسخ فقط «V1 مجانية بالكامل» من ق-10.

546. Subscription deferral from ق-10/ق-26 remains active.

547. ق-86 entitlement-per-purchase model remains governing.

548. PA-03 لا تعتبر Production Complete قبل إغلاق م-34.

549. Any DB change جديد يبدأ Migration 078+.

## ق-107 — ثوابت Monitoring/Audit/Configuration

550. Business Dashboard وSystem Monitoring منفصلتان.

551. Monitoring تعرض Symptom قبل Cause.

552. Monitoring لا تعتمد على Color فقط.

553. Alert لا يلزم أن تنشأ لكل Error.

554. Critical/High Alerts يجب أن تكون Actionable.

555. Repeated Alert Events deduplicated/grouped.

556. Incident مستقلة عن Support Case.

557. Major Incident يمكن أن تحصل على Postmortem.

558. Correlation ID تربط User Error بالBackend Context.

559. Full OpenTelemetry ليست Requirement في V1.

560. Existing `audit.audit_logs` هي Audit Foundation.

561. لا Parallel Audit System بلا قرار جديد.

562. Platform Audit access عبر Trusted Admin Projection.

563. Audit payload لا تخزن Secrets عمدًا.

564. Audit sensitive access/export قد يسجل.

565. Audit Retention لا تحدد اعتباطيًا.

566. Technical Telemetry وBusiness Audit يمكن أن تختلف Retention.

567. Platform Config Typed وليست Generic JSON Editor.

568. Sensitive Config Versioned.

569. Config Change Audited.

570. Rollback لا يمحو Config History.

571. Config validated before apply.

572. Infrastructure Secrets لا تدخل Platform Settings.

573. Feature Flag ليست Authorization.

574. Client Config لها Safe Defaults.

575. Business/Platform Config Backend-owned في V1.

576. Maintenance Mode Scoped.

577. Maintenance لا تكسر Offline-safe field work.

578. Online-only operation تعرض Maintenance State واضحًا.

579. Emergency Maintenance يمكن أن تحمل Expiry.

580. App Version Policy تفرق Recommended/Minimum/Required.

581. Required Update تستخدم فقط لخطر حقيقي موثق.

582. Offline user لا يقفل عن Local Safe Work بصورة عمياء.

583. Monitoring تربط errors بالإصدار والتغيير عند الإمكان.

584. Provider Down لا يستنتج من Error محلي واحد.

585. Telemetry تقلل PII.

586. Internal Account ID مفضل على الهاتف للتشخيص.

587. Crash/Error Telemetry لا تخزن Password/Token.

588. Admin Security View لا تعرض Secrets.

589. Infrastructure Secrets تدار خارج Business Settings UI.

590. Backup Status read-only عند توفر Truth موثوق.

591. لا ordinary Database Dump button في V1.

592. لا one-click Production Restore في V1.

593. Final Admin Sidebar محدودة بـ12 قسمًا رئيسيًا.

594. Technical internals لا تتوسع كSidebar sections مستقلة.

595. Global Search تبقى Toolbar capability.

596. Public Status Page مؤجلة.

597. Custom SIEM مؤجل.

598. Full OpenTelemetry rollout مؤجل.

599. Advanced experimentation مؤجل.

600. Custom Admin Roles مؤجلة حتى الحاجة الفعلية.

601. Shared Platform Admin Accounts غير مقبولة عند تعدد المسؤولين.

602. PA-01..PA-04 مكتملة تصميميًا بعد ق-107.

603. Design Complete لا تعني Implemented.

604. PA-04 لا تعتبر Production Complete قبل إغلاق م-35.

605. Any new DB change يبدأ Migration 078+.
