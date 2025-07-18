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
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Global variables
late String deviceId;
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Get or generate a persistent device ID
  deviceId = await _getDeviceId();
  print('Device ID: $deviceId');

  await _initializeNotifications();
  await _requestPermissions();
  await initializeService();

  runApp(MyApp());
}

// Get a persistent device ID
Future<String> _getDeviceId() async {
  // First check if we already have a stored ID
  final prefs = await SharedPreferences.getInstance();
  String? storedId = prefs.getString('device_id');

  if (storedId != null && storedId.isNotEmpty) {
    return storedId;
  }

  // If not, generate a new one based on device info
  final deviceInfo = DeviceInfoPlugin();
  String id;
  try {
    if (Theme.of(GlobalKey<NavigatorState>().currentContext!).platform ==
        TargetPlatform.android) {
      final androidInfo = await deviceInfo.androidInfo;
      id = androidInfo.id; // Android ID
    } else {
      id = DateTime.now().millisecondsSinceEpoch.toString();
    }
  } catch (e) {
    // Fallback if device info fails
    id = 'device_${DateTime.now().millisecondsSinceEpoch}';
    print('Error getting device info: $e');
  }

  // Store for future use
  await prefs.setString('device_id', id);
  return id;
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
              Text(
                'Socket Connection Active\nDevice ID: $deviceId',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () async {
                  await _showNotification(
                    'Test notification\nDevice ID: $deviceId',
                  );
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
      initialNotificationContent:
          'Socket service is running\nDevice ID: $deviceId',
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

  // Get the device ID in the background service context
  final prefs = await SharedPreferences.getInstance();
  final serviceDeviceId = prefs.getString('device_id') ?? 'unknown';

  // Initialize notifications in background service
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('app_icon');

  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );

  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  bool isRunning = true;
  io.Socket? socket;
  Timer? reconnectTimer;
  Timer? heartbeatTimer;
  bool isConnecting = false;
  int reconnectAttempts = 0;
  const int maxReconnectAttempts = 5;
  const Duration initialReconnectDelay = Duration(seconds: 5);

  void connectSocket() {
    // Prevent multiple connection attempts
    if (isConnecting) return;
    isConnecting = true;

    // Calculate backoff delay based on reconnect attempts
    final reconnectDelay = Duration(
      milliseconds:
          initialReconnectDelay.inMilliseconds *
          (1 << min(reconnectAttempts, 5)),
    );

    // Update service notification to show connecting status
    service.invoke('update', {
      'title': 'Socket Service',
      'content': 'Connecting to server...\nDevice ID: $serviceDeviceId',
    });

    // Disconnect existing socket if any
    socket?.disconnect();
    socket = null;

    socket = io.io("http://192.168.1.106:8080", <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
      'timeout': 20000,
      'forceNew': true,
      'query': {
        'deviceId': serviceDeviceId,
      }, // Send device ID as a query parameter
    });

    socket!.onConnect((_) {
      print('Connected. Socket ID: ${socket!.id}, Device ID: $serviceDeviceId');
      socket!.emit('register', {
        'deviceId': serviceDeviceId,
      }); // Register with device ID

      // Reset reconnect attempts on successful connection
      reconnectAttempts = 0;

      // Update service notification to show connected status
      service.invoke('update', {
        'title': 'Socket Service',
        'content': 'Connected - Socket active\nDevice ID: $serviceDeviceId',
      });

      // Cancel reconnect timer if running
      reconnectTimer?.cancel();
      isConnecting = false;
    });

    socket!.onDisconnect((_) {
      print('Disconnected - Device ID: $serviceDeviceId');

      // Update service notification to show disconnected status
      service.invoke('update', {
        'title': 'Socket Service',
        'content':
            'Disconnected - Trying to reconnect...\nDevice ID: $serviceDeviceId',
      });

      // Try to reconnect after 5 seconds
      if (isRunning) {
        isConnecting = false;
        reconnectAttempts++;

        reconnectTimer = Timer(reconnectDelay, () {
          if (isRunning) {
            print('Attempting to reconnect (attempt $reconnectAttempts)');
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
        if (socket != null && socket!.connected) {
          socket!.emit('sms_status', {
            'deviceId': serviceDeviceId,
            'status': status.toString(),
            'timestamp': DateTime.now().toIso8601String()
          });
        }
      };
      // send sms message
      // telephony.sendSms(
      //   to: "00963945494513",
      //   message: "Hi , How are you ?!",
      //   statusListener: listener,
      // );
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

      print("Message received: $data");
    });

    socket!.onError((error) {
      print("Socket error: $error");
      isConnecting = false;
    });

    socket!.onConnectError((error) {
      print("Socket connection error: $error");
      isConnecting = false;
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
    print("Background process is now stopped");
  });

  // Heartbeat to keep socket alive and emit periodic messages
  heartbeatTimer = Timer.periodic(const Duration(minutes: 30), (timer) {
    if (isRunning && socket != null && socket!.connected) {
      socket!.emit("heartbeat", {
        "deviceId": serviceDeviceId,
        "timestamp": DateTime.now().toIso8601String(),
      });
      print("Service is running - heartbeat sent at ${DateTime.now()}");
    } else if (isRunning && (socket == null || !socket!.connected)) {
      print("Socket disconnected, attempting reconnection...");
      connectSocket();
    }
  });
}
