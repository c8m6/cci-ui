define cci::certificate (
  Pattern[/^[a-z][a-z0-9_]{0,47}$/] $area,
  String[1] $path,
  String[1] $lookup = $title,
  Optional[String] $key_path = undef,
  Optional[String] $version = undef,
  Boolean $include_chain = false,
  String $owner = 'root',
  String $group = 'root',
) {
  $field = $include_chain ? { true => 'chain', false => 'certificate' }
  file { $path:
    ensure    => file,
    content   => cci::lookup($area, $lookup, $field, $version),
    checksum  => 'sha256',
    owner     => $owner,
    group     => $group,
    mode      => '0644',
    show_diff => false,
  }
  if $key_path {
    file { $key_path:
      ensure    => file,
      content   => cci::lookup($area, $lookup, 'private_key', $version),
      checksum  => 'sha256',
      owner     => $owner,
      group     => $group,
      mode      => '0600',
      show_diff => false,
      backup    => false,
    }
  }
}
