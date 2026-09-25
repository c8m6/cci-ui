# frozen_string_literal: true

# Resolves a validated OmniAuth result into the application identity and roles.
class OidcAuthorization
  Result = Data.define(:identity, :details, :reason, :failure_detail) do
    def allowed? = reason.nil?
  end

  def initialize(auth:, auth_mode:, client_id:, role_mapping:)
    @auth = auth
    @auth_mode = auth_mode
    @client_id = client_id
    @role_mapping = role_mapping
  end

  def call
    return denied("authentication_failed", "auth_mode_mismatch") unless @auth_mode == "oidc"
    return denied("identity_missing", "omniauth_auth_missing") unless @auth
    return denied("authentication_failed", "provider_mismatch") unless @auth.provider.to_s == "keycloak"

    info = raw_info
    return denied("required_claim_missing", "raw_info_missing") unless info

    user = @auth.uid.to_s
    return denied("required_claim_missing", "uid_missing", info: info, missing_claims: ["omniauth.uid"]) if user.empty?
    return denied("user_disabled", "enabled_claim_false", info: info, user: user) if info["enabled"] == false

    role_details = role_details(info)
    mapped_roles = role_details.fetch(:incoming_roles).flat_map do |role|
      Array(@role_mapping.fetch(role, role))
    end.uniq
    identity = Identity.new(name: user, roles: mapped_roles)
    details = base_details.merge(claim_details(info), role_details,
      user: user, identity_source: "omniauth.uid", mapped_roles: mapped_roles,
      accepted_application_roles: AreaConfiguration.roles, required_roles: [],
      effective_roles: identity.roles, discarded_roles: mapped_roles - identity.roles)
    Result.new(identity: identity, details: details, reason: nil, failure_detail: nil)
  end

  private

  def raw_info
    value = @auth.extra&.raw_info
    value.respond_to?(:to_h) ? value.to_h.deep_stringify_keys : nil
  end

  def role_details(info)
    group_roles = string_values(info["groups"])
    realm_roles = string_values(nested(info, "realm_access", "roles"))
    client_roles = string_values(nested(info, "resource_access", @client_id, "roles"))
    sources = {
      "groups" => group_roles,
      "realm_access.roles" => realm_roles,
      "resource_access.#{@client_id}.roles" => client_roles
    }
    {
      role_sources: sources.keys.select { |path| claim_present?(info, path) },
      group_roles: group_roles, realm_roles: realm_roles, client_roles: client_roles,
      incoming_roles: sources.values.flatten.uniq,
      matched_role_mappings: sources.values.flatten.uniq.select { |role| @role_mapping.key?(role) }
    }
  end

  def claim_details(info)
    values = relevant_claim_values(info)
    {
      claim_paths_checked: values.keys,
      relevant_claims_present: values.filter_map { |path, value| path unless value.nil? }
    }
  end

  def claim_present?(info, path)
    !relevant_claim_values(info).fetch(path).nil?
  end

  def nested(value, *keys)
    keys.reduce(value) { |current, key| current.is_a?(Hash) ? current[key] : nil }
  end

  def string_values(value)
    Array(value).grep(String).uniq
  end

  def relevant_claim_values(info)
    {
      "sub" => info["sub"], "preferred_username" => info["preferred_username"], "email" => info["email"],
      "enabled" => info["enabled"], "groups" => info["groups"],
      "realm_access.roles" => nested(info, "realm_access", "roles"),
      "resource_access.#{@client_id}.roles" => nested(info, "resource_access", @client_id, "roles")
    }
  end

  def checked_claim_paths
    ["sub", "preferred_username", "email", "enabled", "groups", "realm_access.roles",
      "resource_access.#{@client_id}.roles"]
  end

  def denied(reason, failure_detail, info: nil, user: nil, missing_claims: nil)
    details = base_details
    details = details.merge(claim_details(info)) if info
    details = details.merge(user: user, identity_source: "omniauth.uid") if user
    details = details.merge(missing_claims: missing_claims) if missing_claims
    Result.new(identity: nil, details: details, reason: reason, failure_detail: failure_detail)
  end

  def base_details
    {
      auth_present: !@auth.nil?, auth_mode: @auth_mode,
      provider: @auth&.provider&.to_s, expected_provider: "keycloak", client_id: @client_id,
      claim_paths_checked: checked_claim_paths
    }
  end
end
