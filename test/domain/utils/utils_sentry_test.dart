// ignore_for_file: deprecated_member_use

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msk_utils/msk_utils.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sentry/sentry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    UtilsSentry.resetTestOverrides();
    UtilsSentry.init(
      'https://examplePublicKey@o0.ingest.sentry.io/0',
      'msk_utils_test',
      '1.0.0',
      sendInDebug: true,
    );
    UtilsSentry.configureForTests(
      packageInfoLoader: () async => PackageInfo(
        appName: 'msk_utils_test',
        packageName: 'msk_utils_test',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
        installerStore: null,
      ),
      platformDetailsLoader: () async => <String, dynamic>{'platform': 'test'},
    );
  });

  test('nao propaga falha do envio do SDK', () async {
    UtilsSentry.configureForTests(
      sentryEventSender: (
        SentryClient client,
        SentryEvent event, {
        StackTrace? stackTrace,
      }) async {
        throw StateError('sdk offline');
      },
    );

    await expectLater(
      UtilsSentry.reportError(StateError('erro original'), StackTrace.current),
      completes,
    );
  });

  test('nao propaga falha ao coletar contexto do dispositivo', () async {
    SentryEvent? capturedEvent;

    UtilsSentry.configureForTests(
      platformDetailsLoader: () async {
        throw StateError('device info indisponivel');
      },
      sentryEventSender: (
        SentryClient client,
        SentryEvent event, {
        StackTrace? stackTrace,
      }) async {
        capturedEvent = event;
      },
    );

    await UtilsSentry.reportError(
      StateError('erro original'),
      StackTrace.current,
    );

    expect(
      capturedEvent?.extra?['observabilityDeviceInfoError'],
      contains('device info indisponivel'),
    );
  });

  test('nao gera erro assincrono nao tratado em fire-and-forget', () async {
    Object? uncaughtError;

    await runZonedGuarded(
      () async {
        UtilsSentry.configureForTests(
          sentryEventSender: (
            SentryClient client,
            SentryEvent event, {
            StackTrace? stackTrace,
          }) async {
            throw StateError('sdk offline');
          },
        );

        UtilsSentry.reportError(
          StateError('erro sem await'),
          StackTrace.current,
        );

        await Future<void>.delayed(Duration.zero);
      },
      (Object error, StackTrace stackTrace) {
        uncaughtError = error;
      },
    );

    expect(uncaughtError, isNull);
  });

  test('desabilita de forma segura quando o DSN esta ausente', () async {
    int captureCount = 0;

    UtilsSentry.init('', 'msk_utils_test', '1.0.0', sendInDebug: true);
    UtilsSentry.configureForTests(
      sentryEventSender: (
        SentryClient client,
        SentryEvent event, {
        StackTrace? stackTrace,
      }) async {
        captureCount++;
      },
    );

    await UtilsSentry.reportError(
      StateError('erro original'),
      StackTrace.current,
    );

    expect(UtilsSentry.enabled, false);
    expect(captureCount, 0);
  });

  test('sanitiza contexto nao serializavel sem crash', () async {
    SentryEvent? capturedEvent;

    UtilsSentry.configureForTests(
      sentryEventSender: (
        SentryClient client,
        SentryEvent event, {
        StackTrace? stackTrace,
      }) async {
        capturedEvent = event;
      },
    );

    await UtilsSentry.reportError(
      StateError('erro original'),
      StackTrace.current,
      data: <String, dynamic>{'customObject': _BrokenToString()},
    );

    final Map<dynamic, dynamic>? json =
        capturedEvent?.extra?['json'] as Map<dynamic, dynamic>?;
    expect(json?['customObject'], '[unsupported observability value]');
  });

  test('nao entra em recursao ao falhar durante a propria captura', () async {
    int captureCount = 0;

    UtilsSentry.configureForTests(
      sentryEventSender: (
        SentryClient client,
        SentryEvent event, {
        StackTrace? stackTrace,
      }) async {
        captureCount++;
        await UtilsSentry.reportError(
          StateError('erro interno do reporter'),
          StackTrace.current,
        );
      },
    );

    await UtilsSentry.reportError(
      StateError('erro original'),
      StackTrace.current,
    );

    expect(captureCount, 1);
  });

  test('configureSentry e seguro mesmo com bootstrap sem observabilidade', () {
    UtilsSentry.init('', 'msk_utils_test', '1.0.0', sendInDebug: true);

    expect(UtilsSentry.configureSentry, returnsNormally);
    expect(FlutterError.onError, isNotNull);
  });

  test('preserva o erro original e sua stack trace', () async {
    final StateError originalError = StateError('erro original');
    StackTrace? originalStackTrace;

    Future<void> operacaoInstrumentada() async {
      try {
        throw originalError;
      } catch (error, stackTrace) {
        originalStackTrace = stackTrace;
        await UtilsSentry.reportError(error, stackTrace);
        return Future<void>.error(error, stackTrace);
      }
    }

    try {
      await operacaoInstrumentada();
      throw StateError('A operacao deveria relancar o erro original.');
    } catch (error, stackTrace) {
      expect(identical(error, originalError), isTrue);
      expect(stackTrace.toString(), originalStackTrace.toString());
    }
  });

  test('nao altera o retorno da operacao instrumentada', () async {
    Future<int> operacaoInstrumentada() async {
      const int resultadoEsperado = 42;
      try {
        return resultadoEsperado;
      } catch (error, stackTrace) {
        await UtilsSentry.reportError(error, stackTrace);
        rethrow;
      }
    }

    expect(await operacaoInstrumentada(), 42);
  });
}

class _BrokenToString {
  @override
  String toString() {
    throw StateError('toString quebrou');
  }
}
