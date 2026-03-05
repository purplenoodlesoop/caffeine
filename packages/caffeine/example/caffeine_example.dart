import 'package:caffeine/caffeine.dart';

class Union<T> {
  final T data;

  const Union(this.data);
}

mixin $ {}

typedef LoggerState = ({int logsCount});

enum LogLevel { info }

typedef LoggerEvent = (LogLevel level, String message);

void logEvent(LoggerEvent event) {
  print('[${event.$1}] ${event.$2}');
}

final logger = Store<LoggerState, LoggerEvent>(
  (self) => (
    () => ((logsCount: 0), Stream.empty),
    (event, state) => (
      (logsCount: state.logsCount + 1),
      () async* {
        logEvent(event);
      },
    ),
  ),
);

typedef RemoteConfigState = ({String apiUrl, int number});

sealed class RemoteConfigEvent<T> = Union<T> with $;

final class LoadRemoteConfig = RemoteConfigEvent<()> with $;

final class UpdateRemoteConfigState = RemoteConfigEvent<RemoteConfigState>
    with $;

Future<RemoteConfigState> fetchRemoteConfig() => throw 'hello';

final remoteConfig = Store<RemoteConfigState, RemoteConfigEvent>(
  subscribe: (state) => Stream.periodic(
    const Duration(minutes: 10),
    (_) => const LoadRemoteConfig(()),
  ),
  (self) => (
    () => (
      (apiUrl: 'https://example.com/api', number: 42),
      () async* {
        yield self(const LoadRemoteConfig(()));
      },
    ),
    (event, state) => switch (event) {
      LoadRemoteConfig() => (
        state,
        () async* {
          yield logger((.info, 'Requesting remote config...'));
          final newValue = await fetchRemoteConfig();
          yield self(UpdateRemoteConfigState(newValue));
        },
      ),
      UpdateRemoteConfigState(data: final newState) => (newState, Stream.empty),
    },
  ),
);

final systemState = Stateful(
  ($) =>
      (url: $(remoteConfig).apiUrl, doubledMessages: $(logger).logsCount * 2),
);

void main() {}
