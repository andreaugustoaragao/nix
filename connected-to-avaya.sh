#!/bin/sh

URL="http://confluence.forge.avaya.com"

/run/current-system/sw/bin/curl -sSf $URL 1>/dev/null 2>/dev/null

if [ $? -eq 0 ]; then
  echo "%{F#CD291D}AVAYA"
else
  echo ""
fi
