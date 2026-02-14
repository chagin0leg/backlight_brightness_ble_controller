abstract class BrightnessProvider {
  String get sourceDescription;

  Future<int?> getBrightness();
}
