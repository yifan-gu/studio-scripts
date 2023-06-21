#!/bin/bash

# Usage: gen-transcript.sh file [language] [model]

PATH_TO_WHISPER="${PATH_TO_WHISPER:-${HOME}/github.com/ggerganov/whisper.cpp}"
FILE=${1}
LANG=${2:-chinese}
MODEL=${3:-small}
FILEBASE=$(basename ${FILE%.MP4})

ffmpeg -i ${FILE} -ar 16000 -ac 1 -c:a pcm_s16le ${FILEBASE}.wav -y;
${PATH_TO_WHISPER}/main -m ${PATH_TO_WHISPER}/models/ggml-${MODEL}.bin -l ${LANG} -osrt -f ${FILEBASE}.wav -of ${FILEBASE}

rm -fr ${FILEBASE}.wav
