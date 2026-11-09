# Cue mobile

A Flutter version of Cue's teleprompter and recording studio, separate from the
Next.js application. Targets Android 7.0 (API 24) and iOS 15 or later.

## Run

Install the Flutter SDK and the platform tooling described in the
[Flutter setup guide](https://docs.flutter.dev/get-started/install). Run:

```text
flutter pub get
flutter run
flutter test
flutter analyze
```

Android builds need the Android SDK and Java 17. iOS builds and signing require
Xcode on a Mac. The generated `com.example.cue_mobile` application/bundle ID
and signing configuration are placeholders: change them before publishing.
Camera recording and permissions must be tested on physical Android and iOS
devices; simulator camera support varies.

## Recording

Enable the camera and microphone, edit or paste a script, select portrait or
landscape capture, and start recording. The prompt scrolls over the live preview
only; it is not burned into the recording. Pause or resume the prompt without
pausing video, finish the take, preview it, and use **Share video** to export it
through the native share sheet. Mirror changes the preview only.

Finished takes are temporary files, are not uploaded, and are not automatically
placed in Photos or Gallery. Share the take before closing the app or starting a
retake to keep a copy. The share target determines whether and where it saves
the video. Backgrounding releases the camera and finishes an active take;
enable the camera again after returning.

## Optional Firebase

Firebase initialization and Storage/Analytics accessors are available for future
use, as in the web project. No recording is uploaded. Configure a separate
native Firebase app for each platform and pass all five values with
`--dart-define=FIREBASE_API_KEY=...`, `FIREBASE_APP_ID`,
`FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_PROJECT_ID`, and
`FIREBASE_STORAGE_BUCKET`. The app ID and API key must match the Android or iOS
Firebase app being built; do not reuse the web app ID. No values are required
for local recording. Dart defines are embedded in the app and must not contain
secrets. Incomplete or invalid configuration is shown in the studio.
