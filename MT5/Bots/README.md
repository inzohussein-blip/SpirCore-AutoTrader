# 🤖 SpirCore Test Bots + Indicators / بوتات ومؤشرات الاختبار

بوتات **MQL5 مستقلة تماماً** (بلا أي include من المشروع) مبسّطة للاختبار السريع — تُسحب مباشرةً على شارت XAUUSD أو **Strategy Tester** لتقارن أداء كل استراتيجية بمفردها. بجانبها **مؤشرات احترافية** تُرسم على الشارت.

> هذه للاختبار/المقارنة. للتشغيل الكامل (ECN + مخاطر + داشبورد) استخدم **`MT5/Experts/SpirCore_EA.mq5`**.

---

## 📦 البوتات (`MT5/Bots/`)
كل بوت: دخول على إغلاق الشمعة بإشارة الاستراتيجية، **فلتر سبريد**، **لوت ثابت**، **SL/TP ثابت بالنقاط**، صفقة واحدة في المرة. لكل بوت **Magic مختلف** فتعمل معاً دون تعارض.

| البوت | الاستراتيجية | النوع | Magic |
|-------|-------------|-------|:-----:|
| `SpirBot_CEZLSMA.mq5` | Chandelier Exit + ZLSMA + Heikin-Ashi | اتجاه | 500002 |
| `SpirBot_BBRSI.mq5` | Bollinger Bands + RSI | ارتداد | 500001 |
| `SpirBot_LRCUTB.mq5` | Linear-Reg Candles + UT Bot | زخم | 500003 |
| `SpirBot_2MACDSTO.mq5` | MACD مزدوج + Stochastic | زخم | 500004 |
| `SpirBot_NWE.mq5` | Nadaraya-Watson Envelope + RSI | ارتداد | 500005 |

**الإعدادات المشتركة**: `InpLot`, `InpSL`, `InpTP` (نقاط), `InpMaxSpread`, `InpMagic` + معاملات كل استراتيجية.

---

## 📉 المؤشرات (`MT5/Indicators/`)
| المؤشر | يرسم |
|--------|------|
| `SpirCore_ZLSMA.mq5` | خط ZLSMA منخفض التأخّر (ذهبي) |
| `SpirCore_ChandelierExit.mq5` | ستوب متحرك: أخضر (صاعد) / أحمر (هابط) |
| `SpirCore_NWEnvelope.mq5` | مغلّف Nadaraya-Watson (منتصف + علوي/سفلي) |

---

## 🛠️ التركيب في MetaEditor
1. في MT5 اضغط `F4` (MetaEditor).
2. **Navigator**: انسخ ملفات `MT5/Bots/*.mq5` إلى مجلد `MQL5/Experts/`، وملفات `MT5/Indicators/*.mq5` إلى `MQL5/Indicators/`.
3. افتح كل ملف واضغط **Compile** (`F7`) — المطلوب **0 errors**.
4. **للاختبار التاريخي**: افتح **Strategy Tester** (`Ctrl+R`)، اختر البوت والرمز XAUUSD والفريم والفترة، ثم **Start**.
5. **للاختبار الحي**: اسحب البوت على شارت XAUUSD (Demo) مع تفعيل **Algo Trading**، واسحب المؤشرات على نفس الشارت.

---

## ⚠️ ملاحظات مهمة
- **بسّطناها عمداً** (SL/TP ثابت، بلا ECN/trailing) لتكون سريعة وواضحة للمقارنة — قد يختلف أداؤها قليلاً عن النواة الكاملة.
- **لم تُجمَّع هنا** (لا MetaEditor في بيئة التطوير) — جمّعها بـ `F7` وأبلغ بأي خطأ.
- **اختبرها على Demo/Tester أولاً.** لا استراتيجية تضمن الربح — استخدم `bridge/backtest.py --walkforward` للتحقق قبل أي مال حقيقي.
