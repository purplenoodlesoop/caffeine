import 'package:caffeine/caffeine.dart';

typedef LoggerState = ({int logsCount});

final logMessage = Event<String>();

final logger = Store<LoggerState>.accum((ctx) {
  ctx.on(logMessage, (msg) async* {
    print(msg);
    yield (logsCount: ctx.current.logsCount + 1);
  });
  return (logsCount: 0);
});

typedef RemoteConfigState = ({String apiUrl, int number});

final loadRemoteConfig = Event<void>();

Future<RemoteConfigState> fetchRemoteConfig() => throw 'hello';

final remoteConfig = Store<RemoteConfigState>.accum((ctx) {
  ctx.on(loadRemoteConfig, (_) async* {
    logMessage(ctx, 'Requesting remote config...');
    yield await fetchRemoteConfig();
  });
  loadRemoteConfig(ctx, null);

  return (apiUrl: 'https://example.com/api', number: 42);
});

final systemState = Store.derive(
  (source) => (
    url: remoteConfig(source).apiUrl,
    doubledMessages: logger(source).logsCount * 2,
  ),
);

void main() {}
