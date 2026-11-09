import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Firebase is optional and is never used to upload recordings automatically.
class FirebaseSupport {
  FirebaseSupport._(this.app);

  final FirebaseApp app;

  FirebaseStorage get storage => FirebaseStorage.instanceFor(app: app);

  FirebaseAnalytics get analytics => FirebaseAnalytics.instanceFor(app: app);

  static Future<FirebaseSupport?> initialize() async {
    const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
    const appId = String.fromEnvironment('FIREBASE_APP_ID');
    const senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
    const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
    const bucket = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');
    final values = [apiKey, appId, senderId, projectId, bucket];
    if (values.every((value) => value.isEmpty)) return null;
    if (values.any((value) => value.isEmpty)) {
      throw StateError('Firebase configuration is incomplete.');
    }
    final app = await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: apiKey,
        appId: appId,
        messagingSenderId: senderId,
        projectId: projectId,
        storageBucket: bucket,
      ),
    );
    return FirebaseSupport._(app);
  }
}
