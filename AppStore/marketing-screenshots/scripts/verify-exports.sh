#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
root="${1:-${script_dir:h}/exports/iphone-6.9}"
locales=(en-US ru uk)
files=(01-hero.png 02-device-top.png 03-device-bottom.png 04-device-top.png)

[[ -d "$root" ]] || { print -u2 "Missing export directory: $root"; exit 1; }

expected_count=$(( ${#locales[@]} * ${#files[@]} ))
actual_count="$(find "$root" -type f -name '*.png' | wc -l | tr -d ' ')"
[[ "$actual_count" == "$expected_count" ]] || {
  print -u2 "Expected $expected_count PNGs, found $actual_count"
  exit 1
}

for locale in "${locales[@]}"; do
  for filename in "${files[@]}"; do
    image="$root/$locale/$filename"
    [[ -f "$image" ]] || { print -u2 "Missing export: $image"; exit 1; }
    metadata="$(sips -g pixelWidth -g pixelHeight -g hasAlpha -g space "$image")"
    width="$(awk '/pixelWidth/{print $2}' <<< "$metadata")"
    height="$(awk '/pixelHeight/{print $2}' <<< "$metadata")"
    alpha="$(awk '/hasAlpha/{print $2}' <<< "$metadata")"
    color_space="$(awk '/space/{print $2}' <<< "$metadata")"
    [[ "$width" == 1320 && "$height" == 2868 && "$alpha" == no && "$color_space" == RGB ]] || {
      print -u2 "Invalid App Store PNG: $image (${width}x${height}, alpha=$alpha, space=$color_space)"
      exit 1
    }
  done
done

print "Verified $expected_count opaque RGB App Store screenshots at 1320x2868."
