define cci::certificate (
  Pattern[/^[a-z][a-z0-9_]{0,47}$/] $area,
  String[1] $path,
  String[1] $certid = $title,
  Optional[String[1]] $lookup = undef,
  Optional[String] $key_path = undef,
  Optional[Integer[1]] $version = undef,
  Boolean $include_chain = false,
  String $owner = 'root',
  String $group = 'root',
) {
  $resolved_certid = $lookup ? { undef => $certid, default => $lookup }
  $field = $include_chain ? { true => 'chain', false => 'certificate' }
  file { $path:
    ensure    => file,
    content   => cci::certid($area, $resolved_certid, $field, $version),
    checksum  => 'sha256',
    owner     => $owner,
    group     => $group,
    mode      => '0644',
    show_diff => false,
  }
  if $key_path {
    file { $key_path:
      ensure    => file,
      content   => cci::certid($area, $resolved_certid, 'private_key', $version),
      checksum  => 'sha256',
      owner     => $owner,
      group     => $group,
      mode      => '0600',
      show_diff => false,
      backup    => false,
    }
  }
}
