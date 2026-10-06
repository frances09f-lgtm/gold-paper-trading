# Gold Paper Trading - Flutter app

Mirror of https://gold-trade-journal.netlify.app/ as a native Android app.
Same Supabase backend, same PIN (no backend changes needed).

## Build the APK (one command)

Install Flutter stable (3.47+), Android SDK, then:

    flutter pub get && flutter build apk --release

Output: build/app/outputs/flutter-apk/app-release.apk

Debug variant (installs alongside, no signing needed):

    flutter build apk --debug

## First run

1. Install the APK, open "Gold Paper Trading".
2. Enter your PIN (same as the web app).
3. Bottom tabs: Trade (live XAU/USD price, Buy/Sell), Positions (open + history),
   Add (manual XM log), Stats (equity curve, reset).

Notes:
- Live price from api.gold-api.com (goldprice.org fallback), refresh every 20s.
- TP/SL switches are stored on-device; auto-close runs only while the app is open.
- INTERNET permission is declared; release builds sign with the debug key by default
  (fine for personal use - add your own signing config for distribution).
