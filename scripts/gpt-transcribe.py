#!/usr/bin/env python3

import argparse
import concurrent.futures
import json
import os
import re
import sys
import time
from pathlib import Path

from openai import OpenAI


MODEL = "gpt-transcribe"
CHUNK_SECONDS = 120
DEFAULT_WORKERS = 8
MAX_RETRIES = 5

SUPPORTED_EXTENSIONS = {".m4a", ".wav"}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Parallel GPT-Transcribe transcription for audio chunks."
    )

    parser.add_argument(
        "input_dir",
        type=Path,
        help="Directory containing .m4a and/or .wav chunks",
    )

    parser.add_argument(
        "output_dir",
        type=Path,
        help="Directory for JSON outputs",
    )

    parser.add_argument(
        "--workers",
        type=int,
        default=DEFAULT_WORKERS,
        help=f"Concurrent API requests (default: {DEFAULT_WORKERS})",
    )

    return parser.parse_args()


def get_chunk_index(path: Path) -> int:
    """
    Expected filenames like:

        2023-a-verite_0000.m4a
        2023-a-verite_0001.wav

    The numeric suffix determines the chunk index.
    """

    match = re.search(r"_(\d+)$", path.stem)

    if not match:
        raise ValueError(
            f"Cannot determine chunk number from filename: {path.name}"
        )

    return int(match.group(1))


def format_duration(seconds: float) -> str:
    seconds = int(seconds)

    hours, remainder = divmod(seconds, 3600)
    minutes, seconds = divmod(remainder, 60)

    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def transcribe_one(
    input_path: Path,
    output_path: Path,
):
    if output_path.exists():
        return {
            "status": "skipped",
            "file": input_path.name,
        }

    chunk_index = get_chunk_index(input_path)
    chunk_offset = chunk_index * CHUNK_SECONDS

    for attempt in range(1, MAX_RETRIES + 1):

        try:
            started = time.monotonic()

            client = OpenAI()

            with input_path.open("rb") as audio_file:

                transcript = client.audio.transcriptions.create(
                    model=MODEL,
                    file=audio_file,

                    languages=["zh", "en"],

                    prompt=(
                        "This is a natural documentary recording. "
                        "Much of the speech may be Shanghainese / Wu Chinese, "
                        "with occasional Mandarin Chinese and English. "
                        "Transcribe the speech as spoken. "
                        "Do not translate Shanghainese into Mandarin. "
                        "Do not guess unclear speech."
                    ),

                    response_format="json",
                )

            result = transcript.model_dump()

            result["source_file"] = input_path.name
            result["chunk_index"] = chunk_index
            result["chunk_offset_sec"] = chunk_offset

            if result.get("segments"):

                for segment in result["segments"]:

                    if "start" in segment:
                        segment["timeline_start_sec"] = (
                            chunk_offset + float(segment["start"])
                        )

                    if "end" in segment:
                        segment["timeline_end_sec"] = (
                            chunk_offset + float(segment["end"])
                        )

            temp_path = Path(str(output_path) + ".tmp")

            with temp_path.open(
                "w",
                encoding="utf-8",
            ) as f:

                json.dump(
                    result,
                    f,
                    ensure_ascii=False,
                    indent=2,
                )

            temp_path.replace(output_path)

            elapsed = time.monotonic() - started

            return {
                "status": "done",
                "file": input_path.name,
                "elapsed": elapsed,
            }

        except Exception as exc:

            if attempt >= MAX_RETRIES:

                return {
                    "status": "failed",
                    "file": input_path.name,
                    "error": str(exc),
                }

            wait_seconds = min(2 ** attempt, 30)

            print(
                f"\nRETRY {attempt}/{MAX_RETRIES - 1}: "
                f"{input_path.name}\n"
                f"{exc}\n"
                f"Waiting {wait_seconds}s...",
                file=sys.stderr,
            )

            time.sleep(wait_seconds)


def main():

    args = parse_args()

    if not os.environ.get("OPENAI_API_KEY"):

        print(
            "ERROR: OPENAI_API_KEY is not set.",
            file=sys.stderr,
        )

        sys.exit(1)

    args.output_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    files = sorted(
        [
            p
            for p in args.input_dir.iterdir()
            if p.is_file()
            and p.suffix.lower() in SUPPORTED_EXTENSIONS
        ]
    )

    if not files:

        print(
            f"No supported audio files found in {args.input_dir}\n"
            f"Supported: {', '.join(sorted(SUPPORTED_EXTENSIONS))}"
        )

        sys.exit(1)

    jobs = []

    for input_path in files:

        output_path = (
            args.output_dir
            / f"{input_path.stem}.json"
        )

        jobs.append(
            (
                input_path,
                output_path,
            )
        )

    total = len(jobs)

    already_done = sum(
        output_path.exists()
        for _, output_path in jobs
    )

    pending_jobs = [
        job
        for job in jobs
        if not job[1].exists()
    ]

    print(f"Model:       {MODEL}")
    print(f"Input:       {args.input_dir}")
    print(f"Output:      {args.output_dir}")
    print(f"Workers:     {args.workers}")
    print(f"Chunks:      {total}")
    print(f"Completed:   {already_done}")
    print(f"Pending:     {len(pending_jobs)}")
    print()

    if not pending_jobs:

        print("Everything is already complete.")
        return

    started = time.monotonic()

    completed_now = 0
    failed = 0

    with concurrent.futures.ThreadPoolExecutor(
        max_workers=args.workers
    ) as executor:

        futures = {
            executor.submit(
                transcribe_one,
                input_path,
                output_path,
            ): input_path

            for input_path, output_path
            in pending_jobs
        }

        for future in concurrent.futures.as_completed(
            futures
        ):

            result = future.result()

            if result["status"] == "done":

                completed_now += 1

            elif result["status"] == "failed":

                failed += 1

                print(
                    f"\nFAILED: {result['file']}\n"
                    f"{result['error']}",
                    file=sys.stderr,
                )

            elapsed = (
                time.monotonic()
                - started
            )

            processed = (
                completed_now
                + failed
            )

            remaining = (
                len(pending_jobs)
                - processed
            )

            if processed > 0:

                avg_seconds_per_job = (
                    elapsed
                    / processed
                )

                eta = (
                    avg_seconds_per_job
                    * remaining
                )

            else:

                eta = 0

            total_completed = (
                already_done
                + completed_now
            )

            print(
                "\r"
                f"PROGRESS: "
                f"{total_completed}/{total} "
                f"| FAILED: {failed} "
                f"| ELAPSED: "
                f"{format_duration(elapsed)} "
                f"| ETA: "
                f"{format_duration(eta)}",
                end="",
                flush=True,
            )

    print()

    if failed:

        print(
            f"Finished with "
            f"{failed} failed chunk(s)."
        )

        sys.exit(2)

    print("Finished successfully.")


if __name__ == "__main__":
    main()
