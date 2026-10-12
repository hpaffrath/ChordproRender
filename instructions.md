# ChordPro & Guitar Pro Editor — Full Deployment Guide

This document provides complete, step-by-step instructions to deploy the entire ChordPro and Guitar Pro Editor from scratch using a free **Supabase Cloud** backend and static web hosting.

---

## Architecture Overview

The system consists of two primary components:
1. **Frontend Client (`chordpro-editor.html`):** A self-contained, single-file HTML/CSS/JavaScript application. It renders chord charts and Guitar Pro tabs (via alphaTab CDN), runs playback via Web Audio/SoundFonts, and connects directly to the database via `@supabase/supabase-js`.
2. **Backend Services (Supabase Cloud):**
   - **PostgreSQL Database:** Stores personal songs, rehearsal notes, user settings, group collaborations, and shared links.
   - **GoTrue Auth:** Handles user registration, email/password login, and JSON Web Token (JWT) issuance.
   - **Row Level Security (RLS):** Enforces data boundaries so users can only access their own songs and groups they belong to.
   - **PostgREST API:** Automatically exposes secure REST endpoints over HTTPS.

---

## Phase 1: Provisioning the Supabase Cloud Backend

### 1.1 Create a Supabase Account & Project
1. Visit [supabase.com](https://supabase.com) and click **Start your project** (or sign in with GitHub).
2. Click **New Project** and select your organization.
3. Configure your project:
   - **Name:** e.g., `chordpro-editor`
   - **Database Password:** Generate and securely save a strong password.
   - **Region:** Choose the region closest to you or your target users (e.g., `ap-southeast-2` for Sydney).
   - **Pricing Plan:** Select the **Free Tier**.
4. Click **Create new project**. Provisioning typically takes 1–2 minutes.

---

### 1.2 Configure Authentication Settings
1. In your Supabase project dashboard, navigate to **Authentication** in the left sidebar.
2. Select **Providers** → **Email**:
   - Ensure **Enable Email provider** is switched **ON**.
   - **Confirm email:**
     - *Recommended for private beta testing:* Turn **OFF** "Confirm email" if you want users to register and immediately appear in the database without waiting for an email verification loop.
     - *For production:* Leave it **ON** to ensure valid email addresses.
3. Click **Save**.

---

### 1.3 Deploy the Database Schema
1. In your project dashboard, navigate to the **SQL Editor** (icon with `>_` in the left sidebar).
2. Click **New query**.
3. Open `schema_full.sql` from your project files and copy its entire contents.
4. Paste the SQL code into the editor pane.
5. Click **Run** (or press `Ctrl+Enter` / `Cmd+Enter`).
6. Confirm the console reports `Success. No rows returned`.

#### What Was Created:
- **`songs` table:** Stores ChordPro text files and Guitar Pro binary payloads (`GPBIN1:<base64>`), metadata (artist, key, tags), and owner IDs.
- **`song_notes` table:** Stores bar-level or song-level rehearsal markers and notes.
- **`user_settings` table:** Key-value store for cross-device preferences (soundfont quality, UI toggles).
- **`approved_members` table:** Private beta gate table preventing unauthorized sign-ins.
- **`groups`, `group_members`, `group_songs`, `group_setlists` tables:** Multi-user band collaboration features.
- **`shared_items` table:** Read-only public sharing tokens for songs and setlists.
- **Security & Triggers:** Automatic timestamp updates, auto-enrollment trigger on user signup, and strict Row Level Security (RLS) policies.

---

### 1.4 Retrieve API Credentials
1. Go to **Project Settings** (gear icon at the bottom of the left sidebar).
2. Select **API** under Configuration.
3. Locate the **Project API keys** and **Project URL** sections and copy:
   - **Project URL:** e.g., `https://abcdefghijklm.supabase.co`
   - **anon / public key:** String starting with `ey...` or `sb_publishable_...` (Safe for client-side use).
   *(Do NOT copy or use the `service_role` key in the HTML file).*

---

## Phase 2: Configuring the Application Code

1. Open `chordpro-editor.html` in any text or code editor.
2. Locate the Supabase configuration block around lines **2244–2245**:

```javascript
// ─── Supabase ────────────────────────────────────────────────────────────────

const SUPABASE_URL = 'https://enrpbyewclsuitcnhhep.supabase.co';
const SUPABASE_KEY = 'sb_publishable_9UjCm2Ggo9Dqo_hvhK_0iA_CpntKhQ0';
