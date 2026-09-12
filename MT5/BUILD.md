# 🛠️ دليل التجميع (Build / Compile) — MQL5

ملفات MQL5 **لم تُجمَّع في بيئة التطوير** (لا MetaEditor على لينكس). راجعتها يدوياً بعناية، لكن التحقق النهائي يتم عندك بـ `F7`. هذا الدليل يجعل الخطوة واضحة، ويخبرك بما تُرسله لي إن ظهر خطأ.

## أين تضع كل ملف (داخل مجلد بيانات MT5)
افتح في MT5: **File ► Open Data Folder**، ثم:

| من المستودع | إلى مجلد MT5 |
|-------------|--------------|
| `MT5/Experts/SpirCore_EA.mq5` | `MQL5/Experts/` |
| `MT5/Experts/SpirCore_Strategies.mqh` | `MQL5/Experts/` (بجانب الـ EA) |
| `MT5/Experts/SpirCore_Risk.mqh` | `MQL5/Experts/` (بجانب الـ EA) |
| `MT5/Bots/SpirBot_*.mq5` | `MQL5/Experts/` |
| `MT5/Indicators/SpirCore_*.mq5` | `MQL5/Indicators/` |

> **مهم**: الـ `.mqh` الثلاثة يجب أن تكون في نفس مجلد `SpirCore_EA.mq5` (لأنه يستعملها عبر `#include "..."`). البوتات والمؤشرات مستقلة — لا تحتاج الـ mqh.

## خطوات التجميع
1. `F4` لفتح **MetaEditor**.
2. افتح كل ملف `.mq5` واضغط **Compile** (`F7`). المطلوب **0 errors**.
   - ابدأ بـ `SpirCore_EA.mq5` (الأكبر، ويجمّع الـ mqh تلقائياً).
   - ثم البوتات، ثم المؤشرات.
3. المؤشرات تظهر تحت **Navigator ► Indicators**، والخبراء/البوتات تحت **Expert Advisors**.

## ترتيب مقترح للاختبار
1. جمّع الكل.
2. على شارت **XAUUSD** (حساب Demo): اسحب أحد `SpirBot_*` في **Strategy Tester** (`Ctrl+R`) لمقارنة سريعة.
3. اسحب المؤشرات الثلاثة على الشارت للتأكد من الرسم.
4. ثم الـ `SpirCore_EA` الكامل + جسر Python + الداشبورد.

## تفعيل WebRequest (للترخيص/النسخ)
`SpirCore_EA` (عند `InpUseLicense`) و`SpirBot_Follower` يستخدمان WebRequest:
**Tools ► Options ► Expert Advisors ► Allow WebRequest for listed URL** → أضِف رابط خادم الـ SaaS (مثل `http://127.0.0.1:9000`).

## إن ظهر خطأ تجميع — أرسل لي هذا بالضبط
لأصلحه فوراً، انسخ من تبويب **Errors** في MetaEditor:
1. **اسم الملف** والسطر (مثال: `SpirCore_EA.mq5(412,7)`).
2. **نص رسالة الخطأ** كاملاً (مثل: `'x' - undeclared identifier`).
3. عدد الـ errors/warnings الإجمالي.

أرسلها كما هي (يمكن لصق عدة أخطاء)، وسأصحّح الأسطر المعنية وأعيد الدفع.

## ما تم التحقق منه يدوياً (مراجعة استباقية)
- تواقيع `OnCalculate` في المؤشرات (صيغة السعر المفردة مقابل OHLC الكاملة).
- عدد وسائط دوال المؤشرات: `iATR/iBands/iRSI/iMACD/iStochastic/iADX`.
- استخدام المصفوفات و`ArraySetAsSeries` و`ArrayInitialize` (تهيئة مصفوفات Chandelier/UT Bot).
- إرجاع الهياكل (`SignalResult`) بالقيمة، و`#include` النسبية.
- overload الصحيح لـ `WebRequest` (7 وسائط) ومحدّدات `%I64d/%I64u`.
- **إصلاح**: حارس نسخ ATR في مؤشر Chandelier لمنع تجاوز حدود المصفوفة أثناء بناء التاريخ.
