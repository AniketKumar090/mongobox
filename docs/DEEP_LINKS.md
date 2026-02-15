# Deep links: Join party link opens the app

When a guest taps the host's join link (**https://mongobox-79a1f.firebaseapp.com/join-queue.html?uid=...**):

- **If they have the MongoBox app installed** → the app can open and show the "Join party" screen (search + add to queue).
- **If they don't have the app** → the link opens in the browser and shows the existing `join-queue.html` page (same flow as today).

For the app to open when the link is tapped, the domain must serve verification files so the OS can associate the link with the app.

## 1. iOS (Universal Links)

Host this file at:

**https://mongobox-79a1f.firebaseapp.com/.well-known/apple-app-site-association**

(No file extension. Content-Type should be `application/json`.)

Example content (adjust `appID` to your team ID + bundle ID, e.g. `B67LY5435D.com.example.mongobox`):

```json
{
  "applinks": {
    "apps": [],
    "details": [
      {
        "appID": "B67LY5435D.com.example.mongobox",
        "paths": ["/join-queue*"]
      }
    ]
  }
}
```

The iOS project already has **Associated Domains** set to `applinks:mongobox-79a1f.firebaseapp.com` in `ios/Runner/Runner.entitlements`.

## 2. Android (App Links)

Host this file at:

**https://mongobox-79a1f.firebaseapp.com/.well-known/assetlinks.json**

You need your app’s **package name** (e.g. `com.example.mongobox`) and the **SHA256 fingerprint** of your signing key (debug or release). Get the fingerprint with:

```bash
keytool -list -v -keystore path/to/keystore -alias your_alias
```

Example content (replace package name and fingerprint):

```json
[
  {
    "relation": ["delegate_permission/common.handle_all_urls"],
    "target": {
      "namespace": "android_app",
      "package_name": "com.example.mongobox",
      "sha256_cert_fingerprints": ["AA:BB:CC:..."]
    }
  }
]
```

## 3. Hosting on Firebase

Firebase Hosting’s default `public` is `build/web`, so you need the `.well-known` files to be served from the root of the domain. Options:

- Add a **rewrite** so `/.well-known/*` is served from a folder you control (e.g. `web/.well-known/`), and put the two files there; or  
- After `flutter build web`, copy the two files into `build/web/.well-known/` before deploying.

Then deploy: `firebase deploy --only hosting`.

After the files are live, test by opening the join link on a device that has the app installed; the app should open to the Join party screen.
