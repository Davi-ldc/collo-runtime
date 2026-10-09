#!/bin/bash
# Ubuntu 24.04 ships kernel.apparmor_restrict_unprivileged_userns=1: a binary
# with no AppArmor profile cannot create user namespaces without privilege,
# and the worker sandbox starts with unshare(CLONE_NEWUSER). This installs a
# profile for one collo binary path that allows userns and confines nothing
# else. The zygote is an exec of that file and workers are clones of the
# zygote, so all three inherit it. Usage: install_apparmor_profile.sh <collo>
set -euo pipefail
bin=$(realpath "${1:?collo binary}")
printf 'abi <abi/4.0>,\ninclude <tunables/global>\n\nprofile collo-runtime %s flags=(unconfined) {\n  userns,\n}\n' "$bin" \
  | sudo -n tee /etc/apparmor.d/collo-runtime >/dev/null
sudo -n apparmor_parser -r /etc/apparmor.d/collo-runtime
echo "apparmor profile collo-runtime loaded for $bin"
