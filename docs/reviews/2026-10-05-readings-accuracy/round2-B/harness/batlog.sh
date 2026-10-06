#!/bin/bash
# samples the battery gauge every 15 s for N iterations
N=${1:-60}
for i in $(seq 1 $N); do
  ts=$(date +%s)
  ior=$(ioreg -rn AppleSmartBattery -w0)
  get(){ echo "$ior" | grep -E "^\s+\"$1\" = " | head -1 | sed -E 's/.*= //'; }
  ut=$(get UpdateTime); v=$(get Voltage); a=$(get Amperage); rc=$(get AppleRawCurrentCapacity); rm=$(get AppleRawMaxCapacity)
  nc=$(get NominalChargeCapacity); cc=$(get CycleCount); t=$(get Temperature); cur=$(get CurrentCapacity); tte=$(get TimeRemaining); avgtte=$(get AvgTimeToEmpty)
  ptd=$(echo "$ior" | grep -o '"PowerTelemetryData" = {[^}]*}' | head -1)
  sl=$(echo "$ptd" | grep -oE '"SystemLoad"=[0-9]+' | cut -d= -f2)
  asl=$(echo "$ptd" | grep -oE '"AccumulatedSystemLoad"=[0-9]+' | cut -d= -f2)
  slc=$(echo "$ptd" | grep -oE '"SystemLoadAccumulatorCount"=[0-9]+' | cut -d= -f2)
  pm=$(pmset -g batt | tail -1 | sed -E 's/.*\t//')
  echo "$ts ut=$ut V=$v A=$a rawCur=$rc rawMax=$rm nominal=$nc cycles=$cc temp=$t cur%=$cur TimeRemaining=$tte AvgTTE=$avgtte SL=$sl ASL=$asl SLC=$slc | $pm"
  sleep 15
done
