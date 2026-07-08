import 'dart:io';
import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sentry/sentry.dart';
import 'package:flutter/widgets.dart';

import 'utils_platform.dart';

class UtilsSentry {
  static String? dsn;
  static String? package;
  static String? version;
  static String environment = 'production';
  static String? organizationSlug;
  static String? projectSlug;
  static String? boardUrl;
  static bool enabled = true;
  static bool sendInDebug = false;
  static Map<String, String> tags = const {};

  /// Inicializa o sentry com alguns dados relevantes, como dsn, o pacote e a versão
  static init(
    String dsn,
    String package,
    String? version, {
    String environment = 'production',
    String? organizationSlug,
    String? projectSlug,
    String? boardUrl,
    bool enabled = true,
    bool sendInDebug = false,
    Map<String, String> tags = const {},
  }) {
    UtilsSentry.dsn = dsn;
    UtilsSentry.package = package;
    UtilsSentry.version = version;
    UtilsSentry.environment = environment;
    UtilsSentry.organizationSlug = organizationSlug;
    UtilsSentry.projectSlug = projectSlug;
    UtilsSentry.boardUrl = boardUrl;
    UtilsSentry.enabled = enabled;
    UtilsSentry.sendInDebug = sendInDebug;
    UtilsSentry.tags = Map<String, String>.unmodifiable(tags);
  }

  static void configureSentry() {
    FlutterError.onError =
        (FlutterErrorDetails details, {bool forceReport = false}) {
      if (UtilsPlatform.isDebug && !UtilsSentry.sendInDebug && !forceReport) {
        // In development mode, simply print to console.
        FlutterError.dumpErrorToConsole(details);
      } else {
        // In production mode, report to the application zone to report to Sentry.
        Zone.current.handleUncaughtError(details.exception, details.stack!);
      }
    };
  }

  static Future<SentryEvent> getSentryEnvEvent(dynamic error) async {
    /// return Event with IOS extra information to send it to Sentry
    final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

    Map<String, dynamic> extra = {
      'platform': UtilsPlatform.isWeb ? '' : Platform.operatingSystem,
      'version': UtilsSentry.version,
      'package': package,
      'sentryEnvironment': UtilsSentry.environment,
      'sentryOrganization': UtilsSentry.organizationSlug,
      'sentryProject': UtilsSentry.projectSlug,
      'sentryBoardUrl': UtilsSentry.boardUrl,
    };

    if (UtilsPlatform.isIOS) {
      final IosDeviceInfo iosDeviceInfo = await deviceInfo.iosInfo;
      extra.addAll({
        'name': iosDeviceInfo.name,
        'model': iosDeviceInfo.model,
        'systemName': iosDeviceInfo.systemName,
        'systemVersion': iosDeviceInfo.systemVersion,
        'localizedModel': iosDeviceInfo.localizedModel,
        'utsname': iosDeviceInfo.utsname.sysname,
        'identifierForVendor': iosDeviceInfo.identifierForVendor,
        'isPhysicalDevice': iosDeviceInfo.isPhysicalDevice,
        'version': UtilsSentry.version,
        'package': package
      });
    } else if (UtilsPlatform.isAndroid) {
      final AndroidDeviceInfo androidDeviceInfo = await deviceInfo.androidInfo;
      extra.addAll({
        'type': androidDeviceInfo.type,
        'model': androidDeviceInfo.model,
        'device': androidDeviceInfo.device,
        'id': androidDeviceInfo.id,
        'androidId': androidDeviceInfo.id,
        'brand': androidDeviceInfo.brand,
        'display': androidDeviceInfo.display,
        'hardware': androidDeviceInfo.hardware,
        'manufacturer': androidDeviceInfo.manufacturer,
        'product': androidDeviceInfo.product,
        'supported32BitAbis': androidDeviceInfo.supported32BitAbis,
        'supported64BitAbis': androidDeviceInfo.supported64BitAbis,
        'supportedAbis': androidDeviceInfo.supportedAbis,
        'isPhysicalDevice': androidDeviceInfo.isPhysicalDevice,
        'package': package,
        'version': androidDeviceInfo.version.codename
      });
    } else if (UtilsPlatform.isMacos) {
      final MacOsDeviceInfo macOsDeviceInfo = await deviceInfo.macOsInfo;
      extra.addAll(macOsDeviceInfo.data);
    } else if (UtilsPlatform.isWindows) {
      final WindowsDeviceInfo windowsDeviceInfo = await deviceInfo.windowsInfo;
      extra.addAll({
        'computerName': windowsDeviceInfo.computerName,
        'numberOfCores': windowsDeviceInfo.numberOfCores,
        'systemMemoryInMegabytes': windowsDeviceInfo.systemMemoryInMegabytes
      });
    } else if (UtilsPlatform.isLinux) {
      final LinuxDeviceInfo linuxDeviceInfo = await deviceInfo.linuxInfo;
      extra.addAll({
        'buildId': linuxDeviceInfo.buildId,
        'id': linuxDeviceInfo.id,
        'machineId': linuxDeviceInfo.machineId,
        'name': linuxDeviceInfo.name,
        'version': linuxDeviceInfo.version,
        'versionId': linuxDeviceInfo.versionId,
      });
    } else if (UtilsPlatform.isWeb) {
      final WebBrowserInfo webBrowserInfo = await deviceInfo.webBrowserInfo;
      extra.addAll({
        'browserName': webBrowserInfo.browserName,
        'deviceMemory': webBrowserInfo.deviceMemory,
        'language': webBrowserInfo.language,
        'hardwareConcurrency': webBrowserInfo.hardwareConcurrency,
        'platform': webBrowserInfo.platform
      });
    }

    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    return SentryEvent(
        release: packageInfo.version,
        environment: UtilsSentry.environment,
        throwable: error,
        timestamp: DateTime.now(),
        tags: UtilsSentry.tags,
        extra: extra);
  }

  static Future<void> reportError(Object error, StackTrace stackTrace,
      {dynamic data, String? dsn}) async {
    if (!UtilsSentry.enabled) {
      return;
    }

    if (UtilsPlatform.isDebug && !UtilsSentry.sendInDebug) {
      // In development mode, simply print to console.
      // Print the full stacktrace in debug mode.
      print(error);
      print(stackTrace);
      return;
    } else {
      try {
        final String? resolvedDsn = dsn ?? UtilsSentry.dsn;
        if (resolvedDsn == null || resolvedDsn.isEmpty) {
          print('Sending report to sentry.io skipped: DSN not configured.');
          return;
        }

        final SentryClient sentry =
            new SentryClient(SentryOptions(dsn: resolvedDsn));

        final SentryEvent event = await getSentryEnvEvent(error);
        if (event.extra != null) {
          event.extra!['json'] = data;
        }
        print('Sending report to sentry.io ${stackTrace.toString()}');
        await sentry.captureEvent(event, stackTrace: stackTrace);
      } catch (e) {
        print('Sending report to sentry.io failed: $e');
        print('Original error: $error');
      }
    }
  }
}
