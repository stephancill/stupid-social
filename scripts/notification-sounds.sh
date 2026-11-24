#!/bin/sh
# Synthesizes the notification sounds Settings offers (Resources/Notification*.caf) with ffmpeg and afconvert,
# and converts Bamboo, the iOS alert tone Telegram offers, from the copy macOS ships. Run from the repository root.
set -eu

out=Resources
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

attack="min(t/0.004,1)"

# name, duration, fade-out start, expression
render() {
	ffmpeg -loglevel error -y -f lavfi -i "aevalsrc='$4':s=44100:d=$2" -af "afade=t=out:st=$3:d=0.05" "$tmp/$1.wav"
	afconvert -f caff -d LEI16 "$tmp/$1.wav" "$out/Notification$1.caf"
}

# Two rising notes.
render Chime 1.1 1.05 "0.45*$attack*(sin(2*PI*1318.5*t)+0.3*sin(2*PI*2637*t))*exp(-7*t)*lt(t,0.14) + 0.5*min((t-0.14)/0.004,1)*gte(t,0.14)*(sin(2*PI*1975.5*t)+0.3*sin(2*PI*3951*t))*exp(-4.5*(t-0.14))"
# One high, clean note.
render Ping 0.9 0.85 "0.6*$attack*(sin(2*PI*1760*t)+0.2*sin(2*PI*3520*t)+0.08*sin(2*PI*5280*t))*exp(-6*t)"
# A short falling blip.
render Pop 0.25 0.2 "0.8*min(t/0.002,1)*sin(2*PI*(260*t+640*0.025*(1-exp(-t/0.025))))*exp(-38*t)"
# A struck bell's inharmonic partials.
render Bell 1.6 1.55 "0.35*$attack*(sin(2*PI*880*t)*exp(-2.6*t)+0.6*sin(2*PI*2428.8*t)*exp(-4*t)+0.4*sin(2*PI*4752*t)*exp(-6*t)+0.25*sin(2*PI*1760*t)*exp(-3*t))"

# The iOS alert tone, as macOS ships it.
afconvert -f caff -d LEI16 /System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Modern/Bamboo.m4r "$out/NotificationBamboo.caf"
