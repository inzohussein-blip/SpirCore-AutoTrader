# 🚀 SpirCore-AutoTrader — Quickstart (دليل التشغيل السريع)

دليل خطوة بخطوة لتشغيل السلسلة الكاملة: **TradingView → إضافة كروم → جسر Python → MT5**.
كل شيء يعمل **محلياً على جهازك** (Windows موصى به لأن مكتبة `MetaTrader5` تعمل على ويندوز).

> ⚠️ **ابدأ دائماً على حساب تجريبي (Demo).** التداول الآلي على الذهب عالي المخاطر.

---

## المتطلبات المسبقة
- منصة **MetaTrader 5** مثبتة ومسجّل الدخول بحساب (Demo أولاً).
- **Python 3.10+**.
- متصفح **Google Chrome**.
- معرفة **اسم رمز الذهب** لدى بروكرك (XAUUSD / GOLD / XAUUSD.m …).

---

## الخطوة 1 — تركيب النواة (EA) في MT5
1. في MT5 اضغط `F4` لفتح **MetaEditor**.
2. في **Navigator** انقر يميناً على **Experts → Open Folder**.
3. انسخ **الملفين** معاً إلى `MQL5/Experts/`:
   - `MT5/Experts/SpirCore_EA.mq5`
   - `MT5/Experts/SpirCore_Strategies.mqh`
4. في MetaEditor افتح `SpirCore_EA.mq5` واضغط **Compile** (`F7`). المطلوب: **0 errors**.
5. في MT5 افتح شارت **XAUUSD** واسحب `SpirCore_EA` عليه.
6. في الإعدادات:
   - عدّل `InpSymbol` ليطابق رمز بروكرك بدقة.
   - اختر `InpStrategy` (مثلاً `STRAT_CEZLSMA`).
   - فعّل **Allow Algo Trading**، وتأكد أن زر **Algo Trading** أعلى المنصة أخضر.
7. ستظهر لوحة الأزرار (يمين أعلى) + الخطان الذهبيان. `AUTO` يبدأ **OFF**.

**اختبار سريع للنواة:** اضغط `BUY` — يجب أن تُفتح صفقة بلوت ثابت ثم تُلحق SL/TP خلال أجزاء من الثانية. اضغط `CLOSE ALL` لإغلاقها.

---

## الخطوة 2 — تشغيل جسر Python
```bash
cd bridge
python -m venv .venv
# Windows:
.venv\Scripts\activate
# macOS/Linux:
# source .venv/bin/activate

pip install -r requirements.txt
copy .env.example .env        # macOS/Linux: cp .env.example .env
```
عدّل ملف `.env`:
- `BRIDGE_AUTH_TOKEN` = نص سري طويل عشوائي (احفظه — ستحتاجه في الإضافة).
- `SYMBOL` = رمز بروكرك.
- `LEVELS_FILE` = المسار الكامل لملف داخل مجلد `MQL5/Files` الخاص بمنصتك، مثال:
  `C:\Users\<you>\AppData\Roaming\MetaQuotes\Terminal\<hash>\MQL5\Files\spircore_levels.csv`

ثم شغّل:
```bash
python server.py
```
**تحقق من العمل:** افتح `http://127.0.0.1:8000/status` — يجب أن يظهر `connected: true` والسبريد الحالي.

---

## الخطوة 3 — تركيب إضافة كروم
1. افتح `chrome://extensions` → فعّل **Developer mode** (يمين أعلى).
2. اضغط **Load unpacked** → اختر مجلد `extension/`.
3. افتح الإضافة من شريط الأدوات وأدخل:
   - **host** = `127.0.0.1` | **port** = `8000`
   - **Auth token** = نفس `BRIDGE_AUTH_TOKEN`
   - **Symbol** = رمز بروكرك | **Lot** = مثلاً `0.10`
4. اضغط **Save & Connect**. يجب أن يتحول المؤشر إلى **online** أخضر.

**اختبار يدوي:** اضغط `BUY` في نافذة الإضافة → تُفتح صفقة عبر الجسر.

---

## الخطوة 4 — ربط تنبيهات TradingView
1. في TradingView أنشئ تنبيهاً (Alert)، واجعل نص الرسالة يبدأ بـ `SPIRCORE`:
   ```
   SPIRCORE BUY
   SPIRCORE SELL XAUUSD 0.20
   SPIRCORE CLOSE
   SPIRCORE DRAW 3358.4 3341.1
   ```
2. تأكد أن تبويب TradingView مفتوح (الإضافة تقرأ **سجل التنبيهات** في نفس الصفحة).
3. عند إطلاق التنبيه، تلتقطه `content.js` وترسله عبر WebSocket → الجسر → MT5.

**اختبار سريع بلا تنبيه حقيقي:** في كونسول صفحة TradingView (`F12`):
```js
window.__spircore("SPIRCORE BUY XAUUSD 0.10")
```

---

## الخطوة 5 — تفعيل الأتمتة الكاملة (اختياري)
- على الشارت اضغط زر `AUTO: OFF` ليصبح `AUTO: ON` (أخضر).
- الآن إشارات الاستراتيجية المختارة تُنفَّذ تلقائياً على إغلاق كل شمعة، مع احترام **فلتر السبريد** وحد الصفقات.
- أبقِه **OFF** أثناء التعلّم؛ الإشارات تظهر على الشريط لتؤكدها يدوياً.

---

## 🧪 مصفوفة اختبار سريعة
| الاختبار | المتوقع |
|---------|---------|
| زر `BUY` على الشارت | صفقة تُفتح ثم SL/TP يُلحقان |
| سبريد أعلى من الحد | منع الدخول + رسالة تحذير |
| `GET /status` | `connected: true` + سبريد |
| زر `BUY` في الإضافة | صفقة عبر الجسر |
| `SPIRCORE DRAW ...` | خطوط زرقاء متقطعة تظهر على شارت MT5 |
| `AUTO: ON` + إشارة استراتيجية | صفقة تلقائية عند إغلاق الشمعة |

---

## 🔧 حل المشكلات
| المشكلة | الحل |
|---------|------|
| الإضافة **offline** | تأكد أن `python server.py` يعمل وأن host/port والتوكن متطابقة |
| لا صفقات من الجسر | تأكد أن MT5 مفتوحة، **Algo Trading** مفعّل، والرمز صحيح |
| `unauthorized` | التوكن في الإضافة/`.env` غير متطابق |
| الخطوط لا تُرسم | `LEVELS_FILE` لا يشير لمجلد `MQL5/Files` الصحيح، أو `InpReadPyLevels=false` |
| خطأ ECN عند الفتح | طبيعي أحياناً؛ الإعادة التلقائية تُلحق SL/TP — راجع سجل Experts |
| `content.js` لا يلتقط | حدّث محددات `ALERT_SELECTORS` حسب واجهة TradingView الحالية |
