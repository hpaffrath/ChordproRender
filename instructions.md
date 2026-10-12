# ChordPro / Guitar Pro Editor — Deployment & Setup Guide

This guide walks you through setting up the database, configuring the application credentials, and hosting the single-file HTML app.

---

## 1. Database Architecture & Requirements

The editor is a client-side Single Page Application (SPA) built with `@supabase/supabase-js`. It connects directly from the browser to the backend without an intermediary server.

### What is Required
1. **PostgreSQL Database** (uses PostgreSQL-specific JSONB, triggers, functions, and Row Level Security).
2. **Supabase Auth (GoTrue)** (manages user signups, passwords, and JSON Web Tokens).
3. **PostgREST** (provides secure REST API endpoints directly over HTTPS).
4. **Row Level Security (RLS)** (secures user data at the database level so users only access their own songs and groups).

### Can MySQL Be Used?
**Not directly.** 
- Browsers cannot connect directly to MySQL over TCP.
- Hardcoding MySQL database credentials into client-side HTML is insecure.
- MySQL lacks native PostgreSQL Row Level Security (RLS) and stored-procedure syntax.
- *To use MySQL*, you would need to build a custom backend API (in PHP, Python, or Node.js) with custom authentication and rewrite all database queries in the HTML file.

### Best Database Options
- **Option A (Recommended & Free):** [Supabase Cloud](https://supabase.com) (free tier includes 500 MB database, auth, and 50,000 monthly active users).
- **Option B (Self-Hosted on your own VPS):** [Supabase via Docker Compose](https://supabase.com/docs/guides/self-hosting/docker) on Hetzner, DigitalOcean, Linode, or any private server.

---

## 2. Setting Up the Database

Follow these steps once you have a Supabase project created (cloud or self-hosted):

### Step 1: Execute the Schema Script
1. Navigate to your Supabase project dashboard.
2. Open the **SQL Editor** from the left-hand navigation.
3. Open the `schema_full.sql` file from this project and copy its entire contents.
4. Paste the script into the SQL Editor and click **Run**.

This script automatically provisions:
- Core tables: `songs`, `song_notes`, `user_settings`, `approved_members`
- Group collaboration tables: `groups`, `group_members`, `group_songs`, `group_setlists`
- Sharing tables: `shared_items`
- Performance indexes, updated-at triggers, and secure Row Level Security (RLS) policies.

### Step 2: Approve Your Admin User
The app includes a private beta access gate (`approved_members` table). Unapproved accounts cannot log in.

1. Launch the app and use **Create Account** to register your email, or create the user in the Supabase Dashboard under **Authentication → Users**.
2. Go to the **SQL Editor** or **Table Editor** in Supabase.
3. In the `approved_members` table, find your email and update `approved` to `true`:
   ```sql
   UPDATE public.approved_members
   SET approved = true
   WHERE email = 'your-email@example.com';
