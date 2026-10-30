# Your Google client ID (about 10 minutes)

Ripple Drive signs in to Google with **your own** OAuth client. That gives you your own Google quota, so you're never slowed down by other people's traffic. Nobody else, including the author of this project, ever sees your login or your files.

Google renames console menus now and then; if a name differs slightly, look for the closest match.

> **"Google Cloud access blocked"?** Google Cloud requires 2-Step Verification. Click **Enable MFA**, turn on 2-Step Verification for your Google account, wait a few minutes, then refresh.

## 1. Create a project

1. Open the [Google Cloud console](https://console.cloud.google.com) with the Google account whose Drive you want to use.
2. Project picker (top left) › **New project** › name it **Ripple Drive** › **Create**, then select it.

## 2. Turn on the Drive API

**APIs & Services › Library** › search **Google Drive API** › **Enable**.

## 3. Set up the sign-in screen

Open **Google Auth Platform** (APIs & Services › OAuth consent screen) and click **Get started** if asked.

1. **Branding:** app name **Ripple Drive**, your email as the support email and developer contact.
2. **Audience:** user type **External**. Under **Test users**, click **Add users** and add your own Gmail address.
3. **Data access** › **Add or remove scopes** › paste `https://www.googleapis.com/auth/drive` (see, edit, create and delete your Drive files) › **Update** › **Save**.

## 4. Create the client

**Clients** › **Create client** › application type **Desktop app** › name **Ripple Drive Mac** › **Create**.

Copy the **client ID** and **client secret**. You paste them into the installer (or `ripple-drive-signin`) in Terminal. They're stored only in `~/.config/rclone/rclone.conf` on your Mac (readable only by you).

**Never put the secret in a repo, an issue or a chat.**

## 5. Sign in

The installer opens Google's sign-in page. Pick your account. On **"Google hasn't verified this app"**, click **Advanced › Go to Ripple Drive (unsafe)**. It's your own app, so this is expected. Then click **Continue** and **Allow**.

## Stop the weekly sign-in

While your app's publishing status is **Testing**, Google ends the sign-in every 7 days. Ripple Drive's icon turns red when that happens; click it and choose **Sign In Again** (about 1 minute).

To stop it, move the app to **In production**:

1. **Branding:** add an **application home page** and a **privacy policy** link. Google may refuse to publish without them.
   - Easy option: fork this repo and turn on **GitHub Pages** (Settings › Pages › Branch `main`, folder `/docs`).
   - Use `https://<you>.github.io/ripple-drive/` as the home page and `.../privacy.html` as the privacy policy.
   - Add `<you>.github.io` under **Authorized domains**. Google may ask you to verify it in [Search Console](https://search.google.com/search-console).
2. **Audience** › **Publish app** › **Confirm**.

You'll still see the "unverified app" warning at sign-in, and an unverified app can have up to 100 users. Neither matters for personal use.

You don't need Google's verification review unless you want to offer the app to the public under one shared client ID.

## Revoke access

Remove **Ripple Drive** at [myaccount.google.com/permissions](https://myaccount.google.com/permissions), or delete the Google Cloud project.
