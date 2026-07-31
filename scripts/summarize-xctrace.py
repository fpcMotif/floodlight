#!/usr/bin/env python3

import json
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict


if len(sys.argv) < 2:
    raise SystemExit(
        "usage: summarize-xctrace.py PROFILE.xml [START_SECONDS] [END_SECONDS]"
    )

start_nanoseconds = int(float(sys.argv[2]) * 1_000_000_000) if len(sys.argv) > 2 else 0
end_nanoseconds = (
    int(float(sys.argv[3]) * 1_000_000_000) if len(sys.argv) > 3 else None
)

binaries = {}
frames = {}
times = {}
weights = {}
threads = {}
backtraces = {}
tagged_stack = []

sample_count = 0
total_weight = 0
leaf_weights = defaultdict(int)
application_weights = defaultdict(int)
system_weights = defaultdict(int)


def referenced_value(element, values, parser):
    reference = element.get("ref")
    return values.get(reference) if reference else parser(element)


for event, element in ET.iterparse(sys.argv[1], events=("start", "end")):
    if event == "start":
        if element.tag == "tagged-backtrace" and element.get("id"):
            tagged_stack.append((element.get("id"), []))
        continue

    if element.tag == "binary" and element.get("id"):
        binaries[element.get("id")] = element.get("name")

    elif element.tag == "frame":
        frame_id = element.get("ref") or element.get("id")
        if element.get("id"):
            binary = element.find("binary")
            binary_name = None
            if binary is not None:
                binary_name = (
                    binaries.get(binary.get("ref"))
                    if binary.get("ref")
                    else binary.get("name")
                )
            frames[frame_id] = {
                "name": element.get("name"),
                "binary": binary_name,
            }
        if tagged_stack and frame_id in frames:
            tagged_stack[-1][1].append(frames[frame_id])

    elif element.tag == "tagged-backtrace" and element.get("id"):
        tagged_id, stack = tagged_stack.pop()
        backtraces[tagged_id] = stack

    elif element.tag == "sample-time" and element.get("id"):
        times[element.get("id")] = int(element.text or 0)

    elif element.tag == "weight" and element.get("id"):
        weights[element.get("id")] = int(element.text or 0)

    elif element.tag == "thread" and element.get("id"):
        threads[element.get("id")] = element.get("fmt")

    elif element.tag == "row":
        time_element = element.find("sample-time")
        thread_element = element.find("thread")
        weight_element = element.find("weight")
        stack_element = element.find("tagged-backtrace")

        if all(
            item is not None
            for item in (time_element, thread_element, weight_element, stack_element)
        ):
            time = referenced_value(
                time_element, times, lambda item: int(item.text or 0)
            )
            thread = referenced_value(
                thread_element, threads, lambda item: item.get("fmt")
            )
            weight = referenced_value(
                weight_element, weights, lambda item: int(item.text or 0)
            )
            stack = backtraces.get(
                stack_element.get("ref") or stack_element.get("id")
            )

            inside_window = (
                time is not None
                and time >= start_nanoseconds
                and (end_nanoseconds is None or time <= end_nanoseconds)
            )
            if (
                inside_window
                and thread
                and thread.startswith("Main Thread")
                and weight
                and stack
            ):
                sample_count += 1
                total_weight += weight
                leaf_weights[stack[0]["name"]] += weight

                unique_frames = {
                    (frame["name"], frame["binary"]) for frame in stack
                }
                for name, binary in unique_frames:
                    if binary == "Floodlight":
                        application_weights[name] += weight
                    elif binary in {"AppKit", "SwiftUI", "SwiftUICore"}:
                        system_weights[name] += weight

        element.clear()


def top_entries(values, limit):
    return [
        {"name": name, "cpu_ms": round(weight / 1_000_000, 3)}
        for name, weight in sorted(
            values.items(), key=lambda item: item[1], reverse=True
        )[:limit]
    ]


print(
    json.dumps(
        {
            "sample_count": sample_count,
            "main_thread_cpu_ms": round(total_weight / 1_000_000, 3),
            "top_leaf_frames": top_entries(leaf_weights, 15),
            "top_floodlight_frames_inclusive": top_entries(
                application_weights, 25
            ),
            "top_ui_framework_frames_inclusive": top_entries(system_weights, 15),
        },
        indent=2,
    )
)
