#!/bin/bash

# Usage: gen-transcript.sh [language] [model]

PATH_TO_WHISPER="${PATH_TO_WHISPER:-${HOME}/github.com/ggerganov/whisper.cpp}"
LANG=${1:-chinese}
MODEL=${2:-small}

for f in `ls *.MP4`;do
  ffmpeg -i $f  -ar 16000 -ac 1 -c:a pcm_s16le ${f%.MP4}.wav -y;
done

mkdir transcript
mv *.wav transcript

cd transcript
for f in `ls *.wav`;do
  ${PATH_TO_WHISPER}/main -m ${PATH_TO_WHISPER}/models/ggml-${MODEL}.bin -l ${LANG} -osrt -f $f -of ${f%.wav}
done

rm -fr *.wav
