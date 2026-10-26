# AviaTrip Android

Это полноценный Android Studio-проект для локальной демоверсии AviaTrip. HTML, CSS и JavaScript включены в APK, поэтому сайт или сервер для запуска не нужен.

## Сборка APK

1. Скачайте репозиторий: GitHub → **Code → Download ZIP**.
2. Распакуйте архив и откройте в Android Studio папку **android**.
3. Используйте JDK 17 и установите Android SDK Platform 35, если IDE попросит.
4. Дождитесь Gradle Sync.
5. Выберите **Build → Build Bundle(s) / APK(s) → Build APK(s)**.

Файл для установки появится в `android/app/build/outputs/apk/debug/app-debug.apk`.

Из терминала в папке `android`:
- Windows: `gradlew.bat assembleDebug`
- Linux/macOS: `./gradlew assembleDebug`

GitHub Actions также собирает APK при изменениях в `android/**`. Запустить сборку вручную можно в репозитории: **Actions → Build Android APK → Run workflow**. APK будет доступен в артефактах успешного запуска.

## Структура

- `app/src/main/java/com/aviatrip/app/MainActivity.kt` — Android-оболочка на Kotlin и WebView.
- `app/src/main/assets/www/index.html` — HTML-интерфейс.
- `app/src/main/assets/www/assets/css/style.css` — стили.
- `app/src/main/assets/www/assets/js/app.js` — логика приложения.
- `app/src/main/res` — название, тема и значок.
- `gradle/wrapper` — Gradle Wrapper.

## Ограничения демоверсии

Рейсы и цены вымышлены; реальной покупки, оплаты и бронирования нет. Профиль, билеты и маршруты сохраняются локально на устройстве. Помощник работает по правилам, это не полноценная языковая модель. Приложение не запрашивает разрешение на интернет и не отправляет данные на сервер.
