class BuildFlags {
  const BuildFlags._();

  static const bool hideDonations = bool.fromEnvironment(
    'SWIFTREMOTE_HIDE_DONATIONS',
    defaultValue: false,
  );

  static const bool showDonations = !hideDonations;
}
