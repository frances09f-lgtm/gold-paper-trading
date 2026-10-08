import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class UserApiKeys {
  static const storage = FlutterSecureStorage();
  static String groq = '';
  static String candles = '';
  static Future<void> load() async {
    groq = await storage.read(key: 'oro_groq_key') ?? '';
    candles = await storage.read(key: 'oro_twelve_data_key') ?? '';
  }

  static Future<void> save(String groqKey, String candleKey) async {
    await storage.write(key: 'oro_groq_key', value: groqKey.trim());
    await storage.write(key: 'oro_twelve_data_key', value: candleKey.trim());
    groq = groqKey.trim();
    candles = candleKey.trim();
  }
}
