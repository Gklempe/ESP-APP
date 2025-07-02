// **ONLY** this file imports dart:html
import 'dart:html' as html;

class NotificationService {
  static Future<void> show({
    required String title,
    required String body,
  }) async {
    // request permission if needed
    if (html.Notification.permission != 'granted') {
      final perm = await html.Notification.requestPermission();
      if (perm != 'granted') return;
    }
    html.Notification(title, body: body);
  }
}
