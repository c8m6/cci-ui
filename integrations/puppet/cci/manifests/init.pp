class cci (
  Hash $certificates = {},
) {
  $certificates.each |String $name, Hash $settings| {
    cci::certificate { $name:
      * => $settings,
    }
  }
}
