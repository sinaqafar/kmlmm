# راهنمای پروژه سنگین خفن

## برای کدی که غوله، هارنس هم باید غول باشه

### 1. Railway پلن
Hobby با 1GB RAM برای پروژه سنگین کمه. برای مونورپو / Next.js بزرگ / میکروسرویس:
- Railway Pro بگیر (8GB RAM, 8 vCPU)
- Settings → Resources → RAM رو ببر روی 4GB حداقل
- Volume رو 20GB کن (cache + node_modules + .next)

### 2. معماری Pi برای پروژه سنگین

**Worktree به جای branch:**
Pi-Web به صورت native از `git worktree` پشتیبانی می‌کنه. برای پروژه سنگین:
- هر فیچر = یک worktree
- هر worktree = یک سشن Pi جدا
- همه موازی بدون تداخل

```
Project: /data/my-monorepo
  Workspace: main (main branch)
  Workspace: feature-auth (worktree)
  Workspace: feature-payment (worktree)
  -> هر کدوم یک Pi سشن جدا
```

**Subagent موازی:**
با `pi-subagents` که نصب کردی، می‌تونی بگی:
> "این تسک رو به 4 تا subagent تقسیم کن: یکی تست‌ها، یکی فرانت، یکی بک، یکی داکر"

### 3. کانتکست میلیاردی
`billion-context` که نصب شده میگه:
- 100K کانتکست کافیه، 5x توکن کمتر، سشن‌های یک‌ماهه با میلیاردها توکن
برای پروژه سنگین یعنی لازم نیست هر بار کل کدبیس رو paste کنی.

فعال‌سازی:
```
/billion-context enable
```

### 4. حافظه هوشمند
برای پروژه سنگین، دو حافظه داری:
- `pi-hermes-memory` → برای پترن‌های کدنویسی تو
- `pi-observational-memory` → برای باگ‌های تکراری پروژه

هر دو با هم تداخل ندارن چون scopeشون فرق داره.

### 5. ترفندهای سرعت

**Cache:**
- `ccache` داخل Dockerfile.heavy هست
- `node_modules` رو داخل Volume نگه دار: `/data/cache`

**LSP:**
`pi-lens` خطاها رو لحظه‌ای نشون میده، لازم نیست هی `npm run lint` بزنی

**Compact:**
وقتی کانتکست پر شد، Pi خودش compaction می‌کنه. با `billion-context` این 5 برابر دیرتر اتفاق میفته.

### 6. دیپلوی سنگین

برای پروژه سنگین از Dockerfile.heavy استفاده کن:
```bash
# تغییر نام
mv Dockerfile.heavy Dockerfile
mv railway.heavy.json railway.json
mv config.heavy.json config.json
git add . && git commit -m "heavy mode" && git push
```

Railway خودش rebuild می‌کنه با 8GB heap.

### 7. مانیتورینگ

داخل Pi بزن:
```
/usage  - هزینه و توکن
/pi-lens status - وضعیت LSP
/subagents status - ساب‌ایجنت‌ها
```

---

اگر پروژه‌ات واقعا عجیب سنگینه (مثلا 500K خط)، بگو استکش چیه (Next.js? Go? Python?) تا Dockerfile رو مخصوص همون بهینه کنم.
