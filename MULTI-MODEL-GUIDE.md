# چند مدل، چند سشن، یک مشورت

## نصب - 2 دقیقه

### 1. کلیدها را به Railway بده (Variables)
```
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
GOOGLE_API_KEY=...
OPENROUTER_API_KEY=sk-or-...
# هرکدام را که داری - حداقل 2 تا برای مشورت لازم است
```

### 2. ایجنت‌ها را کپی کن
فایل‌های `agents-examples/*.md` را ببر به:
```
~/.pi/agent/agents/  (global - همه پروژه‌ها)
یا
/data/my-project/.pi/agents/  (فقط همین پروژه)
```

در Railway: این فایل‌ها را داخل Volume `/data/.pi/agent/agents/` بگذار.

## استفاده - 3 حالت

### حالت 1: موازی - 3 مدل روی یک سوال (مشورت)
```bash
# هر 3 مدل جداگانه auth را تحلیل می‌کنند
/parallel scout-claude "audit auth flow, report risks" | reviewer-gpt "audit auth flow, report risks" | worker-gemini "audit auth flow, report risks"
```
→ 3 سشن جدا بالا می‌آید، هرکدام با مدل خودش. نتیجه هر 3 برمی‌گردد. سپس:
```
/chain oracle-consensus "جمع‌بندی کن: هر 3 گزارش را بخوان و بگو کدام ریسک واقعی است"
```

### حالت 2: زنجیره‌ای - هر مرحله یک مدل متفاوت
```bash
/chain scout-claude "نقشه کد auth را بکش" -> worker-gemini "بر اساس نقشه، فیکس را پیاده کن" -> reviewer-gpt "فیکس را سخت‌گیرانه ریویو کن"
```
→ مرحله 1 با Claude Sonnet (دقیق)، مرحله 2 با Gemini Flash (سریع)، مرحله 3 با GPT (منطقی)

### حالت 3: inline - بدون ساخت فایل
```bash
/parallel scout[model=anthropic/claude-sonnet-4] "audit auth" | scout[model=openai/gpt-4o] "audit auth" | scout[model=google/gemini-2.0-flash] "audit auth"
```

## نکته طلایی برای پروژه سنگین
```bash
# 3 مدل موازی + هرکدام در worktree جدا (تداخل صفر)
/parallel worker-gemini[lane=hard,worktree] "implement feature A" | worker-claude[worktree] "implement feature B" | worker-gpt[worktree] "implement feature C"
→ reviewer-gpt "هر 3 فیچر را یکجا ریویو کن"
```

هر worker در git worktree خودش می‌نویسد → بدون کانفلیکت.

## چک
داخل سشن Pi بزن:
```
/agents  # لیست ایجنت‌ها و مدل‌هاشون
/subagents # مانیتور سشن‌های فعال
```
