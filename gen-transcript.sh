#!/bin/bash

# Usage: gen-transcript.sh file [language]

PATH_TO_WHISPER="${PATH_TO_WHISPER:-${HOME}/github.com/ggerganov/whisper.cpp}"
FILE=${1}
LANG=${2:-chinese}

ffmpeg -i ${FILE}  -ar 16000 -ac 1 -c:a pcm_s16le ${FILE%.MP4}.wav -y;
${PATH_TO_WHISPER}/main -m ${PATH_TO_WHISPER}/models/ggml-small.bin -l ${LANG} -osrt -f ${FILE%.MP4}.wav -of ${FILE%.MP4}

rm -fr ${FILE%.MP4}.wav
