// ignore_for_file: deprecated_member_use

import 'dart:io';
import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sentry/sentry.dart';
import 'package:flutter/widgets.dart';

import 'utils_platform.dart';

typedef _PackageInfoLoader = Future<PackageInfo> Function();
typedef _PlatformDetailsLoader = Future<Map<String, dynamic>> Function();
typedef _SentryClientFactory = SentryClient Function(String dsn);
typedef _SentryEventSender = Future<void> Function(
  SentryClient client,
  SentryEvent event, {
  StackTrace? stackTrace,
});

class UtilsSentry {
  static const Symbol _reportingZoneKey = #mskUtilsSentryReporting;
  static const String _sanitizedFallback = '[unsupported observability value]';
  static const String _circularReferenceFallback =
      '[circular observability value]';

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
  static _PackageInfoLoader _packageInfoLoader = PackageInfo.fromPlatform;
  static _PlatformDetailsLoader _platformDetailsLoader =
      _defaultPlatformDetailsLoader;
  static _SentryClientFactory _sentryClientFactory =
      (String dsn) => SentryClient(SentryOptions(dsn: dsn));
  static _SentryEventSender _sentryEventSender =
      (SentryClient client, SentryEvent event, {StackTrace? stackTrace}) async {
    await client.captureEvent(event, stackTrace: stackTrace);
  };

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
    final String? normalizedDsn = _normalizeDsn(dsn);
    UtilsSentry.dsn = normalizedDsn;
    UtilsSentry.package = package;
    UtilsSentry.version = version;
    UtilsSentry.environment = environment;
    UtilsSentry.organizationSlug = organizationSlug;
    UtilsSentry.projectSlug = projectSlug;
    UtilsSentry.boardUrl = boardUrl;
    UtilsSentry.enabled = enabled && normalizedDsn != null;
    UtilsSentry.sendInDebug = sendInDebug;
    UtilsSentry.tags = Map<String, String>.unmodifiable(tags);
    if (enabled && normalizedDsn == null) {
      _debugLog(
        'Observability disabled because no DSN was configured for package "$package".',
      );
    }
  }

  static void configureSentry() {
    try {
      FlutterError.onError =
          (FlutterErrorDetails details, {bool forceReport = false}) {
        try {
          if (_shouldOnlyLogLocally && !forceReport) {
            FlutterError.dumpErrorToConsole(details);
            return;
          }

          Zone.current.handleUncaughtError(
            details.exception,
            details.stack ?? StackTrace.current,
          );
        } catch (error, stackTrace) {
          _debugLog(
            'Observability bootstrap failed while handling FlutterError: '
            '$error\n$stackTrace',
          );
          FlutterError.dumpErrorToConsole(details);
        }
      };
    } catch (error, stackTrace) {
      _debugLog(
        'Observability bootstrap failed while configuring FlutterError: '
        '$error\n$stackTrace',
      );
    }
  }

  static Future<SentryEvent> getSentryEnvEvent(
    dynamic error, {
    dynamic data,
  }) async {
    /// return Event with IOS extra information to send it to Sentry
    final Map<String, dynamic> extra = {
      'platform': UtilsPlatform.isWeb ? '' : Platform.operatingSystem,
      'version': UtilsSentry.version,
      'package': package,
      'sentryEnvironment': UtilsSentry.environment,
      'sentryOrganization': UtilsSentry.organizationSlug,
      'sentryProject': UtilsSentry.projectSlug,
      'sentryBoardUrl': UtilsSentry.boardUrl,
      'json': _sanitizeValue(data),
    };

    try {
      extra.addAll(_sanitizeMap(await _platformDetailsLoader()));
    } catch (error, stackTrace) {
      extra['observabilityDeviceInfoError'] = 'Device info unavailable: $error';
      _debugLog(
        'Observability failed while collecting device info: '
        '$error\n$stackTrace',
      );
    }

    final String? release = await _safeReleaseVersion();
    return SentryEvent(
      release: release,
      environment: UtilsSentry.environment,
      throwable: error,
      timestamp: DateTime.now(),
      tags: UtilsSentry.tags,
      extra: extra,
    );
  }

  static Future<void> reportError(
    Object error,
    StackTrace stackTrace, {
    dynamic data,
    String? dsn,
  }) async {
    if (!UtilsSentry.enabled) {
      return;
    }

    if (_shouldOnlyLogLocally) {
      // In development mode, simply print to console.
      // Print the full stacktrace in debug mode.
      print(error);
      print(stackTrace);
      return;
    }

    final String? resolvedDsn = _normalizeDsn(dsn ?? UtilsSentry.dsn);
    if (resolvedDsn == null) {
      _debugLog('Observability skipped because no DSN is available.');
      return;
    }

    if (Zone.current[_reportingZoneKey] == true) {
      _debugLog('Recursive observability report skipped for "$error".');
      return;
    }

    await runZoned(
      () async {
        final SentryClient sentry = _sentryClientFactory(resolvedDsn);
        try {
          final SentryEvent event = await getSentryEnvEvent(error, data: data);
          await _sentryEventSender(sentry, event, stackTrace: stackTrace);
        } catch (observabilityError, observabilityStackTrace) {
          _debugLog(
            'Sending report to sentry.io failed: '
            '$observabilityError\n$observabilityStackTrace\nOriginal error: $error',
          );
        }
      },
      zoneValues: {_reportingZoneKey: true},
    );
  }

  static bool get _shouldOnlyLogLocally =>
      UtilsPlatform.isDebug && !UtilsSentry.sendInDebug;

  static String? _normalizeDsn(String? value) {
    final String trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  static Future<String?> _safeReleaseVersion() async {
    try {
      return (await _packageInfoLoader()).version;
    } catch (error, stackTrace) {
      _debugLog(
        'Observability failed while resolving package info: '
        '$error\n$stackTrace',
      );
      return UtilsSentry.version;
    }
  }

  static Future<Map<String, dynamic>> _defaultPlatformDetailsLoader() async {
    final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

    if (UtilsPlatform.isIOS) {
      final IosDeviceInfo iosDeviceInfo = await deviceInfo.iosInfo;
      return {
        'name': iosDeviceInfo.name,
        'model': iosDeviceInfo.model,
        'systemName': iosDeviceInfo.systemName,
        'systemVersion': iosDeviceInfo.systemVersion,
        'localizedModel': iosDeviceInfo.localizedModel,
        'utsname': iosDeviceInfo.utsname.sysname,
        'identifierForVendor': iosDeviceInfo.identifierForVendor,
        'isPhysicalDevice': iosDeviceInfo.isPhysicalDevice,
        'version': UtilsSentry.version,
        'package': package,
      };
    }

    if (UtilsPlatform.isAndroid) {
      final AndroidDeviceInfo androidDeviceInfo = await deviceInfo.androidInfo;
      return {
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
        'version': androidDeviceInfo.version.codename,
      };
    }

    if (UtilsPlatform.isMacos) {
      final MacOsDeviceInfo macOsDeviceInfo = await deviceInfo.macOsInfo;
      return macOsDeviceInfo.data;
    }

    if (UtilsPlatform.isWindows) {
      final WindowsDeviceInfo windowsDeviceInfo = await deviceInfo.windowsInfo;
      return {
        'computerName': windowsDeviceInfo.computerName,
        'numberOfCores': windowsDeviceInfo.numberOfCores,
        'systemMemoryInMegabytes': windowsDeviceInfo.systemMemoryInMegabytes,
      };
    }

    if (UtilsPlatform.isLinux) {
      final LinuxDeviceInfo linuxDeviceInfo = await deviceInfo.linuxInfo;
      return {
        'buildId': linuxDeviceInfo.buildId,
        'id': linuxDeviceInfo.id,
        'machineId': linuxDeviceInfo.machineId,
        'name': linuxDeviceInfo.name,
        'version': linuxDeviceInfo.version,
        'versionId': linuxDeviceInfo.versionId,
      };
    }

    if (UtilsPlatform.isWeb) {
      final WebBrowserInfo webBrowserInfo = await deviceInfo.webBrowserInfo;
      return {
        'browserName': webBrowserInfo.browserName,
        'deviceMemory': webBrowserInfo.deviceMemory,
        'language': webBrowserInfo.language,
        'hardwareConcurrency': webBrowserInfo.hardwareConcurrency,
        'platform': webBrowserInfo.platform,
      };
    }

    return const {};
  }

  static Map<String, dynamic> _sanitizeMap(Map<String, dynamic> source) {
    final Map<String, dynamic> sanitized = <String, dynamic>{};
    source.forEach((dynamic key, dynamic value) {
      sanitized[key.toString()] = _sanitizeValue(value);
    });
    return sanitized;
  }

  static dynamic _sanitizeValue(dynamic value, [Set<int>? seen]) {
    seen ??= <int>{};

    if (value == null || value is num || value is bool || value is String) {
      return value;
    }

    if (value is DateTime) {
      return value.toIso8601String();
    }

    if (value is Duration || value is Uri) {
      return value.toString();
    }

    if (value is Map) {
      final int identity = identityHashCode(value);
      if (!seen.add(identity)) {
        return _circularReferenceFallback;
      }

      final Map<String, dynamic> sanitized = <String, dynamic>{};
      value.forEach((dynamic key, dynamic nestedValue) {
        sanitized[_safeToString(key)] = _sanitizeValue(nestedValue, seen);
      });
      seen.remove(identity);
      return sanitized;
    }

    if (value is Iterable) {
      final int identity = identityHashCode(value);
      if (!seen.add(identity)) {
        return _circularReferenceFallback;
      }

      final List<dynamic> sanitized = value
          .map((dynamic item) => _sanitizeValue(item, seen))
          .toList(growable: false);
      seen.remove(identity);
      return sanitized;
    }

    return _safeToString(value);
  }

  static String _safeToString(dynamic value) {
    try {
      return value.toString();
    } catch (_) {
      return _sanitizedFallback;
    }
  }

  static void _debugLog(String message) {
    if (UtilsPlatform.isDebug) {
      debugPrint(message);
    }
  }

  @visibleForTesting
  static void configureForTests({
    _PackageInfoLoader? packageInfoLoader,
    _PlatformDetailsLoader? platformDetailsLoader,
    _SentryClientFactory? sentryClientFactory,
    _SentryEventSender? sentryEventSender,
  }) {
    _packageInfoLoader = packageInfoLoader ?? _packageInfoLoader;
    _platformDetailsLoader = platformDetailsLoader ?? _platformDetailsLoader;
    _sentryClientFactory = sentryClientFactory ?? _sentryClientFactory;
    _sentryEventSender = sentryEventSender ?? _sentryEventSender;
  }

  @visibleForTesting
  static void resetTestOverrides() {
    _packageInfoLoader = PackageInfo.fromPlatform;
    _platformDetailsLoader = _defaultPlatformDetailsLoader;
    _sentryClientFactory =
        (String dsn) => SentryClient(SentryOptions(dsn: dsn));
    _sentryEventSender = (
      SentryClient client,
      SentryEvent event, {
      StackTrace? stackTrace,
    }) async {
      await client.captureEvent(event, stackTrace: stackTrace);
    };
  }
}
