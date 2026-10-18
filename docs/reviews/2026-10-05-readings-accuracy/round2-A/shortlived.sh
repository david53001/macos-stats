#!/bin/bash
end=$((SECONDS+8))
while [ $SECONDS -lt $end ]; do dd if=/dev/zero of=/dev/null bs=1m count=3000 2>/dev/null; done
