import 'store.dart';
import 'store_reference.dart';

class StoreOverride<S, E> implements StoreReference {
  final Store<S, E> from;
  final Store<S, E> to;

  StoreOverride(this.from, this.to);
}
