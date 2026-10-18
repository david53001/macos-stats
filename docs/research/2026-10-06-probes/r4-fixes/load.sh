#!/bin/bash
# Bursty short-lived processes (two loops, ~0.7 core on average) until killed.
loop() { while true; do /usr/bin/yes >/dev/null & p=$!; sleep 0.$((RANDOM % 9 + 1)); kill $p 2>/dev/null; wait $p 2>/dev/null; sleep $((RANDOM % 2)).$((RANDOM % 9 + 1)); done; }
loop & loop & wait
