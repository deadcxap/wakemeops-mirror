#!/bin/bash
set -eu
umask 022
nginx -e stderr -g 'daemon off;' &
python3 -u /usr/local/lib/mirror.py &
# Either long-lived process exiting should restart the container. Tini forwards
# stop signals to the whole process group, including a running debmirror.
wait -n
exit 1
