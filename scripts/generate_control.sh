#!/bin/bash

CONTROL_FILE="controls_byterazor-fhem-ntfy.txt"

if [ -e $CONTROL_FILE ]; then
  rm $CONTROL_FILE
fi

find ./FHEM -type f \( ! -iname "0.*" \) -print0 | while IFS= read -r -d '' f;
do
        out="UPD $(stat --format "%z %s" $f | sed -e "s#\([0-9-]*\)\ \([0-9:]*\)\.[0-9]*\ [+0-9]*#\1_\2#") $f"
        echo "${out//.\//}" >> $CONTROL_FILE
done


#generate CHANGELOG
rm CHANGED
DATE=
git log --no-merges --pretty=format:'%ci|%s' | while read -r line; do
  CDATE=$(echo "${line}" | awk '{print $1}')
  MSG=$(echo "${line}" | awk -F '|' '{print $2}')

  if [ "$DATE" != "$CDATE" ]; then
    DATE=$CDATE
    echo "$DATE" >> CHANGED
  fi

  echo "    ${MSG}" >> CHANGED

done
