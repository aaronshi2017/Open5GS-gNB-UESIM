#!/bin/bash
ip route add 10.46.0.0/16 via 10.33.33.4 2>/dev/null || true
exec kamailio -DD -E
