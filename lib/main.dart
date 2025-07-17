import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:another_telephony/telephony.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:vibration/vibration.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final deviceId = Random().nextInt(10);
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await _initializeNotifications();
  await _requestPermissions();
  await initializeService();

  runApp(MyApp());
}

Future<void> _initializeNotifications() async {
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('app_icon');

  const DarwinInitializationSettings initializationSettingsIOS =
      DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    iOS: initializationSettingsIOS,
  );

  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  // Create notification channel for Android
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'socket_messages',
    'Socket Messages',
    description: 'Notifications for socket messages',
    importance: Importance.high,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);
}

Future<void> _requestPermissions() async {
  // Request notification permission for Android 13+
  if (await Permission.notification.isDenied) {
    await Permission.notification.request();
  }

  // Request SMS permission if needed
  if (await Permission.sms.isDenied) {
    await Permission.sms.request();
  }

  // Check if permissions are granted
  final notificationStatus = await Permission.notification.status;
  if (notificationStatus.isDenied || notificationStatus.isPermanentlyDenied) {
    print('Notification permission denied');
    // You might want to show a dialog explaining why the permission is needed
  }
}

Future<void> _showNotification(String message) async {
  const AndroidNotificationDetails androidPlatformChannelSpecifics =
      AndroidNotificationDetails(
        'socket_messages',
        'Socket Messages',
        channelDescription: 'Notifications for socket messages',
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
        styleInformation: BigTextStyleInformation(''),
      );

  const NotificationDetails platformChannelSpecifics = NotificationDetails(
    android: androidPlatformChannelSpecifics,
  );

  await flutterLocalNotificationsPlugin.show(
    0,
    'Socket Message',
    message,
    platformChannelSpecifics,
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Socket App')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Socket Connection Active',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () async {
                  await _showNotification('Test notification');
                },
                child: const Text('Test Notification'),
              ),
              ElevatedButton(
                onPressed: startBackgroundService,
                child: const Text('Start Service'),
              ),
              ElevatedButton(
                onPressed: stopBackgroundService,
                child: const Text('Stop Service'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void startBackgroundService() {
  final service = FlutterBackgroundService();
  service.startService();
}

void stopBackgroundService() {
  final service = FlutterBackgroundService();
  service.invoke("stop");
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
    androidConfiguration: AndroidConfiguration(
      autoStart: true,
      onStart: onStart,
      isForegroundMode: true,
      autoStartOnBoot: true,
      notificationChannelId: 'socket_messages',
      initialNotificationTitle: 'Socket Service',
      initialNotificationContent: 'Socket service is running',
      foregroundServiceNotificationId: 888,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  final Telephony telephony = Telephony.instance;

  // Initialize notifications in background service
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('app_icon');
  // AndroidInitializationSettings('@mipmap/ic_launcher');

  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );

  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  bool isRunning = true;
  io.Socket? socket;
  Timer? reconnectTimer;
  Timer? heartbeatTimer;

  void connectSocket() {
    socket = io.io("http://192.168.1.106:8080", <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
      'timeout': 20000,
      'forceNew': true,
    });

    socket!.onConnect((_) {
      print('Connected. Socket ID: ${socket!.id}');
      socket!.emit('message', 'phone connected');

      // Update service notification to show connected status
      service.invoke('update', {
        'title': 'Socket Service',
        'content': 'Connected - Socket active',
      });

      // Cancel reconnect timer if running
      reconnectTimer?.cancel();
    });

    socket!.onDisconnect((_) {
      print('Disconnected');

      // Update service notification to show disconnected status
      service.invoke('update', {
        'title': 'Socket Service',
        'content': 'Disconnected - Trying to reconnect...',
      });

      // Try to reconnect after 5 seconds
      if (isRunning) {
        reconnectTimer = Timer(const Duration(seconds: 5), () {
          if (isRunning) {
            connectSocket();
          }
        });
      }
    });

    socket!.on("message", (data) async {
      if (await Vibration.hasVibrator() == true) {
        Vibration.vibrate();
      }
      
      final SmsSendStatusListener listener = (SendStatus status) {
        // TODO send the status back to socket
        print('SmsSendStatusListener: $status');
      };
      // send sms message
      telephony.sendSms(
        to: "00963945494513",
        message: "Hi , How are you ?!",
        statusListener: listener,
      );
      // Show notification
      const AndroidNotificationDetails androidPlatformChannelSpecifics =
          AndroidNotificationDetails(
            'socket_messages',
            'Socket Messages',
            channelDescription: 'Notifications for socket messages',
            importance: Importance.high,
            priority: Priority.high,
            showWhen: true,
            styleInformation: BigTextStyleInformation(''),
          );

      const NotificationDetails platformChannelSpecifics = NotificationDetails(
        android: androidPlatformChannelSpecifics,
      );

      await flutterLocalNotificationsPlugin.show(
        DateTime.now().millisecondsSinceEpoch.remainder(100000),
        'Socket Message',
        data.toString(),
        platformChannelSpecifics,
      );

      print("message received: $data");
    });

    socket!.onError((error) {
      print("Socket error: $error");
    });
  }

  // Initial connection
  connectSocket();

  service.on("stop").listen((event) {
    isRunning = false;
    reconnectTimer?.cancel();
    heartbeatTimer?.cancel();
    socket?.disconnect();
    service.stopSelf();
    print("background process is now stopped");
  });

  // Heartbeat to keep socket alive and emit periodic messages
  heartbeatTimer = Timer.periodic(const Duration(hours: 2), (timer) {
    if (isRunning && socket != null && socket!.connected) {
      socket!.emit("message", "app message aftwer two hours $deviceId");
      print("service is successfully running ${DateTime.now().second}");
    } else if (isRunning && (socket == null || !socket!.connected)) {
      print("Socket disconnected, attempting reconnection...");
      connectSocket();
    }
  });
}
