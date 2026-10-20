# MBA Fast Downloader (Windows & Android)

شتہارات سے پاک (100% Ad-Free)، تیز رفتار ملٹی پلیٹ فارم ویڈیو اور فائل ڈاؤن لوڈر برائے **ونڈوز کمپیوٹر (Windows)** اور **اینڈرائیڈ موبائل (Android)**۔

## GitHub سے خودکار `.exe` اور `.apk` حاصل کرنے کا طریقہ

1. GitHub پر ایک نیا مفت Repository بنائیں (مثلاً `mba-fast-downloader`)۔
2. اس پروجیکٹ کی تمام فائلیں (بشمول `.github/workflows/build.yml`، `lib/`، `test/`، `android_custom/` اور `pubspec.yaml`) اپ لوڈ کر کے **Commit** کریں۔
3. اوپر **Actions** ٹیب پر کلک کریں۔
4. چند منٹ میں GitHub کا سرور خودکار طور پر کوڈ چیک (`flutter analyze` اور `flutter test`) کرے گا اور آپ کو دو تیار فائلیں دے دے گا:
   - **`MBA-Fast-Downloader-Android-APK`**: اینڈرائیڈ موبائل میں انسٹال کرنے کے لیے `.apk` فائل۔
   - **`MBA-Fast-Downloader-Windows-Portable`**: ونڈوز کمپیوٹر پر چلانے کے لیے `mba_fast_downloader.exe` اور اس کی تمام ضروری فائلیں۔
