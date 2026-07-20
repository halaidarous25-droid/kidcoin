# KidCoins — بنك العائلة 🏦
### ✅ LIVE — connected to Supabase

**Project:** kidcoins-family-bank · **Org:** KidCoin · **Region:** London (eu-west-2)
**URL:** https://ecuqkmvhrkulebmwmwan.supabase.co
Database is fully provisioned: 9 tables, 13 RLS policies, 7 functions, 3 triggers, pgcrypto.
`js/config.js` already contains the live credentials — no need to edit it.

**Remaining one-time step:** in the Supabase dashboard, open **Authentication → Providers → Email**,
enable it, and turn **Confirm email = ON**. Then add your GitHub Pages URL under
**Authentication → URL Configuration → Redirect URLs**.

---


## 📁 What's in this bundle

| File | Purpose |
|---|---|
| `index.html` | Marketing landing page (public) |
| `auth.html` | Sign up / Log in / Child login (Supabase Auth) |
| `dashboard.html` | **Cloud app** — live parent + child dashboards on Supabase |
| `app.html` | Original rich app (offline/demo engine) |
| `js/config.js` | **Your Supabase credentials** (you edit this) |
| `js/kidcoins-api.js` | Data-access layer (auth + CRUD + realtime) |
| `supabase/schema.sql` | Complete database (tables, security, triggers) |
| `kidcoins-promo.mp4` | Promo video used on the landing page |



### 🚪 Front door = the landing page
`index.html` (the landing page) is the site's main entry — GitHub Pages serves it at
the root URL. Customers enter the system entirely through it:

- **Start Free** → `auth.html#signup`  (create a family account)
- **Log In** → `auth.html#login`
- The landing detects a **returning, logged-in customer** and switches its main button
  to **“Open my dashboard”**, sending them straight to `dashboard.html` — no re-login.

Full path: `index.html` → `auth.html` → `dashboard.html` (with the app guarding sessions
and bouncing anyone unauthenticated back to `auth.html`).

### 🌩️ The cloud app (`dashboard.html`)
This is the real multi-user application, fully wired to Supabase:
- **Parent dashboard** — family header with a copyable **family code**, live children
  cards with real balances, add-child (name, username, PIN, avatar, colour), per-child
  actions (reward / deduct / assign task), a **pending-approvals** queue, recent activity,
  and **realtime updates** (changes appear instantly across devices).
- **Child view** — balance, assigned tasks, and personal activity.
- Auth-guarded: no session → redirected to `auth.html`.

The flow is: `index.html` → `auth.html` (sign up / log in) → `dashboard.html`.

---

## 🚀 Setup (about 10 minutes)

### 1) Create the Supabase project
1. Go to <https://supabase.com> → **New project** (free tier is fine).
2. Choose a name and a strong database password → **Create**.
3. Wait ~2 minutes for it to provision.

### 2) Build the database
1. In Supabase: **SQL Editor → New query**.
2. Open `supabase/schema.sql`, copy **all** of it, paste, and click **Run**.
3. You should see “Success. No rows returned.” This created every table,
   security rule, trigger and function.

### 3) Turn on authentication
1. **Authentication → Providers → Email**: make sure it is **enabled**.
2. **Authentication → Sign In / Providers → Email**: turn **Confirm email = ON**
   (recommended for a commercial product — you chose this).
3. **Authentication → URL Configuration → Redirect URLs**: add your site URL,
   e.g. `https://YOURNAME.github.io/family-bank-firebase/`.

### 4) Add your keys
1. **Project Settings → API**. Copy **Project URL** and the **anon public** key.
2. Open `js/config.js` and paste them in:
   ```js
   SUPABASE_URL:      'https://xxxx.supabase.co',
   SUPABASE_ANON_KEY: 'eyJhbGciOi...'
   ```
   > The anon key is meant to be public — Row Level Security protects the data.
   > **Never** put the `service_role` key in these files.

### 5) Publish on GitHub Pages
1. Upload all files (keep the `js/` folder structure) to your repo
   `family-bank-firebase`.
2. **Settings → Pages → Source: main branch / root → Save**.
3. Your site is live at `https://YOURNAME.github.io/family-bank-firebase/`.

Done. Visit the site → **Sign Up** → confirm the email → you're in.

---

## 🔐 How authentication works

**Parents** — real accounts via Supabase Auth (email + password, email-confirmed).
On signup a database trigger automatically creates their **profile**, a **family**,
and an **owner membership**.

**Children** — two supported ways (you chose both):
- **On the parent's device:** the parent is logged in; children switch with a 4-digit PIN.
- **Independent login:** the child uses the **family code** (found in app settings) +
  their **username** + **PIN** on `auth.html → Child Login`. This calls a secure
  `child_login` database function that verifies a bcrypt-hashed PIN and never exposes it.

---

## 🛡️ Security model

- **Row Level Security (RLS)** on every table — a parent can only ever read/write
  data belonging to a family they are a member of. Enforced in the database, not the UI.
- **PINs are hashed** with bcrypt (`pgcrypto`), never stored or returned in plain text.
- **`SECURITY DEFINER` functions** (`create_child`, `child_login`, `set_child_pin`)
  perform privileged checks server-side.
- The **anon key** is safe to expose; all trust lives in RLS + Auth.

---

## 🗄️ Database at a glance

```
profiles ──1:1── auth.users
families ──owner── profiles
family_members (family ⇄ parents, multi-parent ready)
children (PIN-hashed, balance kept live by triggers)
transactions (signed ledger; a trigger updates child balances on approve)
tasks · savings_goals · store_items · purchases
```

Key automation:
- **New user → profile + family + membership** (trigger `on_auth_user_created`).
- **Approved transaction → child balance updated** (trigger `trg_tx_balance`),
  and reversed automatically if a transaction is rejected or deleted.

---

## 🔌 Using the API layer (`window.KC`)

```js
// Parent
await KC.signUp({ email, password, fullName, familyName });
await KC.signIn({ email, password });
const fams = await KC.myFamilies();
await KC.createChild({ familyId, name, username, pin:'1234', avatar:'🦁' });
await KC.addTransaction({ familyId, childId, type:'task_reward', amount:50, description:'ترتيب الغرفة' });

// Child (independent)
await KC.childLogin({ familyCode:'ABCD1234', username:'faris', pin:'1234' });

// Realtime
KC.subscribeFamily(familyId, payload => console.log('changed', payload));
```

---

## 🧩 Migration note (localStorage → Supabase)

The current `app.html` ships with its original offline (localStorage) engine **plus**
the Supabase layer and an auth guard. It runs in two modes:

- **Configured** (`js/config.js` filled): unauthenticated visitors are redirected to
  `auth.html`; use `window.KC` to move each feature's reads/writes to Supabase.
- **Not configured** (placeholders left in): the app keeps working fully offline —
  perfect for demos.

Porting each screen's data calls to `window.KC` can be done screen-by-screen without
downtime, since both engines coexist. The backend, auth, security and data layer are
already production-ready.

---

## 📄 License
© 2025 KidCoins. All rights reserved.
