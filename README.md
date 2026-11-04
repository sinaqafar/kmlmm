# Pi-Web روی Railway - راهنمای کامل

## هشدار امنیتی بسیار مهم ⚠️
PI WEB به صورت پیش‌فرض **هیچ احراز هویتی** ندارد و برای شبکه امن طراحی شده [pi-web.dev/install](https://pi-web.dev/install):
> PI WEB is designed for trusted users and trusted server paths. Do not expose it directly to the public internet.

اگر مستقیم روی Railway public domain بالا بیاری، هر کسی می‌تونه به ایجنتت دسترسی داشته باشه و کد اجرا کنه!

**راه حل امن (پیشنهادی):**
1. در Railway یک Caddy با Basic Auth جلوی Pi-Web بذار (فایل Caddyfile داخل همین پوشه)
2. یا از Tailscale/WireGuard استفاده کن و Pi-Web رو فقط روی IP خصوصی bind کن

برای تست سریع می‌تونی بدون auth بالا بیاری ولی بلافاصله بعدش auth اضافه کن.

---

## نصب مرحله‌ای

### 1. پوشه را به گیت‌هاب بفرست
```bash
cd railway-pi-web
git init
git add .
git commit -m "pi-web railway"
gh repo create pi-web-railway --public --source=. --push
```

### 2. پروژه جدید در Railway
1. برو railway.com → New Project → Deploy from GitHub repo
2. ریپازیتوری `pi-web-railway` رو انتخاب کن
3. Railway خودش Dockerfile رو تشخیص میده و build می‌کنه

### 3. متغیرهای محیطی را ست کن
در تب Variables سرویس:

```
PORT=8504 (Railway خودش میده، دست نزن مگر لازم شد)
NODE_ENV=production
PI_WEB_HOST=0.0.0.0

# کلیدهای AI - هر کدوم رو که داری
ANTHROPIC_API_KEY=sk-...
OPENAI_API_KEY=sk-...
GEMINI_API_KEY=...
OPENROUTER_API_KEY=...

# اختیار: برای Pi memory
PI_HERMES_MEMORY_AUTO=true
```

### 4. Volume برای persistence
در Railway → سرویس → Settings → Volumes:
- Mount Path: `/data`
- Size: 5GB (کافی برای پروژه‌ها)

بدون Volume هر deploy همه memory و سشن‌ها پاک میشه!

### 5. Domain بگیر
Settings → Networking → Generate Domain
لینکت میشه: `https://pi-web-railway-production.up.railway.app`

### 6. تست
باز کن:
```
https://your-domain.up.railway.app
```
باید Pi-Web رو ببینی. یک پروژه اضافه کن و یک سشن Pi شروع کن.

---

## نسخه امن با Caddy (پیشنهاد می‌شه)

اگر می‌خوای public باشه ولی با پسورد:

1. یک سرویس دوم در همون پروژه Railway بساز از همین Dockerfile ولی CMD رو عوض کن:
```dockerfile
# Dockerfile.secure
FROM caddy:2-alpine
COPY Caddyfile /etc/caddy/Caddyfile
```

2. Caddyfile:
```
:{$PORT} {
  basicauth {
    {$BASIC_USER} {$BASIC_PASS_HASH}
  }
  reverse_proxy pi-web:8504
}
```

یا ساده‌ترین راه: از Cloudflare Tunnel استفاده کن:
```bash
cloudflared tunnel --url http://localhost:8504
```

---

## عیب‌یابی

**پورت باز نمیشه:**
- چک کن `PI_WEB_HOST=0.0.0.0` و `PI_WEB_PORT=$PORT` ست باشه
- لاگ Railway: `pi-web doctor` باید `✓ session daemon running` بده

**اکستنشن‌ها لود نشدن:**
- داخل Railway → Deploy Logs ببین `pi install` ارور داده یا نه
- SSH به کانتینر: `pi list`

**حافظه پاک میشه:**
- Volume روی `/data` ندادی

**انکود فارسی بهم ریخته:**
- TZ=Asia/Tehran ست کن

---

## بروزرسانی اکستنشن‌ها

```bash
# داخل سشن Pi در Railway:
pi update
pi-web restart
```

یا یک push جدید به گیت‌هاب بده، Railway خودکار rebuild می‌کنه.

---

ساخته شده برای Pi Ultimate Harness - تمام Tier 1+2+3 از قبل نصب شده.
