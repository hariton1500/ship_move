class TickEngine {
  final double tickRate;
  double _accumulator = 0;

  TickEngine(this.tickRate);

  void update(double frameDt, void Function(double dt) tick) {
    final dt = 1 / tickRate;
    _accumulator += frameDt;

    while (_accumulator >= dt) {
      tick(dt);
      _accumulator -= dt;
    }
  }
}
