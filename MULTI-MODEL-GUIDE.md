# چند مدل، چند سشن، یک مشورت

این نسخه با اکستنشن‌های واقعی و مدل‌های واقعی تست شده. همه چیز از قبل نصب است —
کافی است کلید NVIDIA را بدهی.

---

## 0. پیش‌نیاز: یک کلید

```
NVIDIA_NIM_API_KEY=nvapi-...
```

از build.nvidia.com → یک model page → **Get API Key**.
در Railway → سرویس → **Variables** بگذار و Redeploy کن.

اکستنشن `pi-nvidia-nim` داخل ایمیج نصب است، پس بعد از ست شدن کلید، مدل‌ها
خودشان در `/model` ظاهر می‌شوند:

```
nvidia-nim/z-ai/glm4.7
nvidia-nim/z-ai/glm5
nvidia-nim/moonshotai/kimi-k2.6
nvidia-nim/deepseek-ai/deepseek-v4-pro      (1M context)
nvidia-nim/qwen/qwen3-coder-480b-a35b-instruct
nvidia-nim/minimaxai/minimax-m3
```

می‌خواهی مدل پیش‌فرض هم عوض شود؟ در model picker روی ستاره‌ی
**New session default** بزن؛ در `/data/.pi/agent/settings.json` ذخیره می‌شود
(`defaultProvider` / `defaultModel`).

---

## 1. شورای ۴ نفره آماده

پوشه `agents/` داخل ایمیج است و در هر بوت به
`/data/.pi/agent/agents/` کپی می‌شود:

| agent | مدل | نقش |
| --- | --- | --- |
| `council-nim-glm` | `z-ai/glm4.7` | مشاور کدنویس |
| `council-nim-kimi` | `moonshotai/kimi-k2.6` | شکارچی محدودیت‌های پنهان |
| `council-nim-deepseek` | `deepseek-ai/deepseek-v4-pro` | ردیابی end-to-end با 1M context |
| `council-chair` | `z-ai/glm4.7` | جمع‌بندی و تصمیم نهایی، بدون ویرایش کد |

اسم‌ها را در سشن چک کن:

```
/subagents list
```

## 2. سه الگوی استفاده

### الف) موازی — سه مدل مستقل روی یک سوال

به زبان طبیعی بگو (Pi خودش ابزار subagent را صدا می‌زند):

```
Run these three advisors in parallel on "audit the auth flow and list real risks":
council-nim-glm, council-nim-kimi, council-nim-deepseek.
Each must cite file paths and command output. Do not share one answer with another.
```

بعد نتیجه‌ها را بده به رئیس شورا:

```
council-chair: read all three reports above. List what they agree on, resolve the
disagreements with evidence from the repo, and write the decision memo.
```

### ب) زنجیره‌ای — هر مرحله یک مدل

```
Use council-nim-deepseek to map every call site that touches auth, then
council-nim-glm to implement the smallest correct fix, then
council-nim-kimi to look for what the fix breaks.
```

### ج) override مدل برای یک اجرا (بدون ساخت فایل)

```
Use reviewer with model nvidia-nim/qwen/qwen3-coder-480b-a35b-instruct
    to review this diff.
```

`reviewer` و `scout`/`worker`/`oracle` از قبل داخل `pi-subagents` هستند.

---

## 3. تنظیم دائمی: هر نقش، یک مدل

در `/data/.pi/agent/settings.json` (روی والیوم، بعد از دیپلوی می‌ماند):

```json
{
  "subagents": {
    "defaultModel": "nvidia-nim/z-ai/glm4.7",
    "agentOverrides": {
      "reviewer": { "model": "nvidia-nim/moonshotai/kimi-k2.6", "thinking": "high" },
      "worker":   { "model": "nvidia-nim/deepseek-ai/deepseek-v4-pro" },
      "scout":    { "model": "nvidia-nim/qwen/qwen3-coder-480b-a35b-instruct" }
    }
  }
}
```

ترتیب اولویت (قوی‌ترین اول): override همان اجرا → override مخصوص provider →
`agentOverrides.<name>.model` → frontmatter فایل agent → `subagents.defaultModel`
→ مدل خود سشن والد.

از داخل UI هم می‌شود: **Settings → Pi packages** و ویرایش تنظیمات، یا
مستقیم ترمینال سشن:

```bash
jq '.subagents.agentOverrides.worker.model = "nvidia-nim/z-ai/glm5"' \
   /data/.pi/agent/settings.json
```

---

## 4. نکات مهم که واقعاً روی خروجی اثر دارند

- **رئیس شورا نباید ادیت کند.** `council-chair` ابزار `edit/write` ندارد؛ اگر
  نقش تصمیم‌گیر را با worker قاطی کنی، مدل‌ها همدیگر را تأیید می‌کنند و
  «مشورت» بی‌اثر می‌شود.
- **context تازه بده، نه forked.** مشاورها باید خودشان فایل را بخوانند. اگر
  transcript والد را fork کنی، هر سه مدل همان فرض‌های غلط والد را تکرار می‌کنند.
- **یک provider = یک rate limit.** روی پلن رایگان NVIDIA، اجرای ۴ مدل موازی
  ممکن است 429 بدهد. برای پروژه سنگین `HEAP_PERCENT` را کم نکن؛ تعداد agent
  موازی را کم کن.
- **مدل‌ها را با هم جمع نکن.** اگر `subagents.defaultModel` را روی مدلی بگذاری
  که provider اش کلید ندارد، همان لحظه خطای
  `No API key found for the selected model` می‌گیری.
- **worktree برای اجرای موازیِ نویسنده‌ها.** دو worker که همزمان یک فایل را
  ادیت کنند، خروجی همدیگر را خراب می‌کنند؛ هر کدام را در worktree جدا بگذار
  (pi-subagents از `lane` / `worktree` پشتیبانی می‌کند).
