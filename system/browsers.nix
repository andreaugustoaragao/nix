_:

# Managed policies for Chromium-based browsers.
# These browsers don't honor XDG_DOWNLOAD_DIR on their own — a managed
# policy is the standard mechanism to set a default download directory.
# The ${user_home} substitution variable is expanded by the browser at
# runtime, so the same policy works for any user.

let
  managedPolicies = {
    DownloadDirectory = "\${user_home}/downloads";
  };
  policyJson = builtins.toJSON managedPolicies;
in
{
  # Chromium reads /etc/chromium/policies/managed/*.json
  programs.chromium = {
    enable = true;
    extraOpts = managedPolicies;
  };

  # Brave reads /etc/brave/policies/managed/*.json
  environment.etc."brave/policies/managed/00-default.json".text = policyJson;
}
