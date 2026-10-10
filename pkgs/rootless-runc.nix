{ docker_29 }:

# With hidepid=2, busctl cannot inspect the user manager that owns the bus
# socket, so its status output omits OwnerUID. RootlessKit already supplies
# the host UID before entering the user namespace. Use that UID for runc's
# user-bus authentication; D-Bus still verifies the connecting credentials.
docker_29.docker-runc.overrideAttrs (oldAttrs: {
  postPatch = (oldAttrs.postPatch or "") + ''
    substituteInPlace vendor/github.com/opencontainers/cgroups/systemd/user.go \
      --replace-fail \
        'b, err := exec.Command("busctl", "--user", "--no-pager", "status").CombinedOutput()' \
        'if raw := os.Getenv("ROOTLESSKIT_PARENT_EUID"); raw != "" {
            uid, err := strconv.Atoi(raw)
            if err != nil || uid <= 0 {
                return -1, fmt.Errorf("invalid ROOTLESSKIT_PARENT_EUID: %q", raw)
            }
            return uid, nil
        }
        b, err := exec.Command("busctl", "--user", "--no-pager", "status").CombinedOutput()'
  '';
})
