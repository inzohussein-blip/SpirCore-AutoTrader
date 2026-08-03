# 🚀 SpirCore-AutoTrader — Quickstart (دليل التشغيل السريع)

دليل خطوة بخطوة لتشغيل السلسلة الكاملة: **TradingView → إضافة كروم → جسر Python → MT5**.
كل شيء يعمل **محلياً على جهازك** (Windows موصى به لأن مكتبة `MetaTrader5` تعمل على ويندوز).

> 🌐 **مساران للتنفيذ:** إمّا **Bridge** (تطبيق MT5 سطح المكتب + جسر Python — انضباط ECN كامل)، أو **MT5 Web** (منصة الويب داخل المتصفح مباشرةً بدون تطبيق ولا جسر). راجع «المسار البديل — وضع MT5 Web» بعد الخطوة 3.

> ⚠️ **ابدأ دائماً على حساب تجريبي (Demo).** التداول الآلي على الذهب عالي المخاطر.

---

## المتطلبات المسبقة
- **للمسار الكامل (Bridge):** منصة **MetaTrader 5** (سطح المكتب) مسجّل الدخول + **Python 3.10+**.
- **لوضع MT5 Web فقط:** يكفي حساب على **منصة MT5 Web** — بدون تطبيق ولا Python.
- متصفح **Google Chrome**.
- معرفة **اسم رمز الذهب** لدى بروكرك (XAUUSD / GOLD / XAUUSD.m …).

---

## الخطوة 1 — تركيب النواة (EA) في MT5
1. في MT5 اضغط `F4` لفتح **MetaEditor**.
2. في **Navigator** انقر يميناً على **Experts → Open Folder**.
3. انسخ **الملفات الثلاثة** معاً إلى `MQL5/Experts/`:
   - `MT5/Experts/SpirCore_EA.mq5`
   - `MT5/Experts/SpirCore_Strategies.mqh`
   - `MT5/Experts/SpirCore_Risk.mqh`
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
   - **Execution mode** = `Auto` (أو `Bridge` لتطبيق سطح المكتب فقط)
   - **host** = `127.0.0.1` | **port** = `8000`
   - **Auth token** = نفس `BRIDGE_AUTH_TOKEN`
   - **Symbol** = رمز بروكرك | **Lot** = مثلاً `0.10`
4. اضغط **Save & Connect**. يجب أن يتحول المؤشر إلى **bridge on** أخضر.

**اختبار يدوي:** اضغط `BUY` في نافذة الإضافة → تُفتح صفقة عبر الجسر.

---

## 🌐 المسار البديل — وضع MT5 Web (بدون تطبيق سطح المكتب ولا جسر Python)
إذا لم ترغب بتشغيل تطبيق MT5 أو جسر Python، يمكنك التداول مباشرةً على **منصة MT5 على الويب**:
1. في نافذة الإضافة اختر **Execution mode = `MT5 Web`** ثم **Save**.
2. افتح منصة MT5 على الويب في تبويب: `https://trade.mql5.com/trade` (أو منصة الويب الخاصة ببروكرك).
3. سجّل الدخول لحسابك، وافتح لوحة **One-Click Trading** (شراء/بيع بنقرة).
4. سيظهر مؤشر الإضافة **web ready** أخضر. الآن أزرار الإضافة وتنبيهات TradingView تنفّذ الصفقات بنقر واجهة المنصة تلقائياً.

**اختبار يدوي** من كونسول صفحة المنصة (`F12`):
```js
window.__spircoreWeb("buy", 0.10)
```
> ⚠️ أتمتة الواجهة تعتمد على محدّدات DOM قد تتغير بين إصدارات المنصة والبروكرز. عدّلها في `extension/mt5web.js` ضمن الثابت `SELECTORS` إن لم تُلتقط الأزرار. وضع الويب **لا يضبط SL/TP تلقائياً** (يعتمد على إعدادات المنصة) — يفضّل استخدام وضع Bridge للانضباط الكامل بأسلوب ECN.

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
