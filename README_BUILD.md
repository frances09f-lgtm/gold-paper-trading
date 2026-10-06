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

## Market data (V2)

- Live XAU/USD bid/ask from the Swissquote public feed (no key needed),
  refreshed every 20s. Gold-api/goldprice.org are mid-only fallbacks.
- Execution is broker-true: buys open at ask / close at bid, sells the
  reverse; the spread is a real cost inside PnL.
- Real candles from Twelve Data (free tier). Pass the key at build time -
  it is never committed:

      flutter build apk --release --dart-define=MARKET_DATA_API_KEY=your_key

  Without the key the chart panel says it is not configured instead of
  drawing demo data. Get a free key at https://twelvedata.com (XAU/USD
  spot works on the free plan, 8 credits/min, 800/day).

Notes:
- TP/SL switches, price alerts, journal notes and the last-known paper
  state are stored on-device; auto-close runs only while the app is open.
- INTERNET permission is declared; release builds sign with the debug key by default
  (fine for personal use - add your own signing config for distribution).
