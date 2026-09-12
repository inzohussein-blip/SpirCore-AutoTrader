# 💼 SpirCore SaaS — licensing, subscriptions, public performance

خدمة خلفية (FastAPI + SQLite) تحوّل SpirCore من أداة شخصية إلى **منتج**: مستخدمون، مفاتيح ترخيص مربوطة بحساب MT5، هيكل اشتراكات (Stripe)، وصفحة أداء عامة.

> ⚠️ **تنبيه صادق**: هذا **أساس منتج** — قيمته الحقيقية تبدأ فقط بعد إثبات أفضلية على Demo/حقيقي بسجل مُدقَّق. بيع نظام غير مُثبَت مضلِّل وقد يخالف تنظيمات مالية. لا تَعِد بأرباح مضمونة.

---

## نقاط الاتصال (Endpoints)
| النقطة | الوصف |
|--------|-------|
| `POST /signup` | تسجيل مستخدم بالبريد |
| `GET  /admin` | **لوحة أدمن** لإدارة التراخيص (HTML) |
| `POST /admin/license` | إصدار ترخيص (يتطلب `x-admin-token`) |
| `POST /admin/revoke` | إلغاء ترخيص (أدمن) |
| `GET  /admin/licenses` | قائمة كل التراخيص + بريد المالك (أدمن) |
| `GET  /license/validate` | **يستدعيها الـ EA** للتحقق (key + account) |
| `POST /performance/report` | يدفع الجسر إحصاءاته (يوثَّق بالترخيص) |
| `GET  /p/{key}` | **صفحة أداء عامة** للقراءة فقط |
| `POST /signals/publish` | الماستر ينشر إشارة (key=مفتاحه، buy/sell/close) |
| `GET  /signals/fetch` | المتابع يجلب الإشارات بعد since (key متابع + channel ماستر) |
| `GET  /signals/latest` | أحدث إشارة (مسطّحة — يسهل على الـ EA قراءتها) |
| `POST /billing/webhook` | Stripe (هيكل — يُوصَل بمفاتيح حقيقية) |

## 📡 النسخ التلقائي (Copy-Trading)
- **القناة = مفتاح ترخيص الماستر.** الماستر ينشر إشاراته، والمتابعون المرخّصون يجلبونها.
- **الماستر تلقائياً**: فعّل في الجسر `SAAS_PUBLISH=true` (+ `SAAS_URL`, `SAAS_LICENSE_KEY`) فيبثّ كل صفقة (فتح/إغلاق) للمتابعين.
- **المتابع**: بوت `MT5/Bots/SpirBot_Follower.mq5` — ضع `InpServerURL` و`InpFollowerKey` (ترخيصك) و`InpChannel` (مفتاح الماستر)، يستطلع `/signals/latest` وينفّذ. (whitelist الرابط في MT5).

## 🛠️ لوحة الأدمن
افتح `http://<host>:9000/admin`، أدخل `SAAS_ADMIN_TOKEN` مرة، ثم **أصدِر/اعرض/ألغِ** التراخيص وتابِع المشتركين وتواريخ الانتهاء من جدول واحد.

## التشغيل محلياً
```bash
cd saas
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env      # عدّل SAAS_ADMIN_TOKEN
uvicorn app:app --host 0.0.0.0 --port 9000
```

## التشغيل عبر Docker (نشر سحابي)
```bash
cd saas
docker build -t spircore-saas .
docker run -d -p 9000:9000 -e SAAS_ADMIN_TOKEN=your-secret \
  -v spircore_data:/data spircore-saas
```
يعمل على أي مزوّد (Fly.io / Render / VPS…) لأنه **لا يعتمد على MetaTrader5** (خلافاً للجسر الذي يبقى على ويندوز).

## دورة الترخيص الكاملة
```
عميل يشترك (Stripe) ─► /billing/webhook يمدّد الترخيص
أدمن يصدر مفتاحاً ─► /admin/license ─► يعطي المفتاح للعميل
EA (InpUseLicense=ON, InpLicenseKey) ─► GET /license/validate كل ساعة
   └─ invalid/expired ─► يوقف التداول تلقائياً
الجسر ─► POST /performance/report ─► صفحة /p/{key} العامة تعرض الأداء
```

## ربط الـ EA
في إعدادات `SpirCore_EA`: فعّل `InpUseLicense`، ضع `InpLicenseURL` (رابط الخدمة) و`InpLicenseKey`.
> يجب إضافة رابط الخدمة في **Tools ► Options ► Expert Advisors ► Allow WebRequest for listed URL** داخل MT5.

## ربط الجسر (دفع الأداء)
في `bridge/.env`: `SAAS_URL=...` و`SAAS_LICENSE_KEY=...` — عندها يدفع الجسر الإحصاءات تلقائياً عند إغلاق كل صفقة.

## توصيل Stripe (لاحقاً)
`/billing/webhook` هيكل جاهز: تحقّق من توقيع `Stripe-Signature`، وعند `invoice.paid` مدّد `db.set_license_expiry`، وعند `subscription.deleted` نفّذ `db.revoke_license`.

## ⚖️ اعتبارات قانونية
أضِف إخلاء مسؤولية واضحاً (موجود في صفحة الأداء)، ولا تَعِد بعوائد، وتحقّق من متطلبات الترخيص المالي في بلدك قبل البيع.
