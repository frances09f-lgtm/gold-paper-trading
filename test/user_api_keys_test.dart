import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gold_paper_trading/user_api_keys.dart';
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 test('keys load and clear from user secure storage only',()async{
  FlutterSecureStorage.setMockInitialValues({'oro_groq_key':'test-groq','oro_twelve_data_key':'test-candles'});
  await UserApiKeys.load();expect(UserApiKeys.groq,'test-groq');expect(UserApiKeys.candles,'test-candles');
  await UserApiKeys.save('new-test','');await UserApiKeys.load();expect(UserApiKeys.groq,'new-test');expect(UserApiKeys.candles,isEmpty);
 });
 test('release workflow never embeds API credentials',(){final s=File('.github/workflows/build-apk.yml').readAsStringSync();expect(s, isNot(contains('dart-define=GROQ_API_KEY')));expect(s,isNot(contains('dart-define=MARKET_DATA_API_KEY')));});
}
