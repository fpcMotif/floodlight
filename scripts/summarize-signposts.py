#!/usr/bin/env python3

import json
import math
import statistics
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict


if len(sys.argv) != 2:
    raise SystemExit("usage: summarize-signposts.py SIGNPOSTS.xml")

values = {}
begins = {}
durations = defaultdict(list)
first_timestamp = None
last_timestamp = None


def value(element):
    reference = element.get("ref")
    if reference:
        stored = values.get(reference, {})
        if element.tag == "event-time":
            return stored.get("text")
        return stored.get("fmt") or stored.get("text")
    if element.tag == "event-time":
        return element.text
    return element.get("fmt") or element.text


for _, element in ET.iterparse(sys.argv[1], events=("end",)):
    if element.get("id") and element.tag != "row":
        values[element.get("id")] = {
            "fmt": element.get("fmt"),
            "text": element.text,
        }

    if element.tag == "row":
        fields = {child.tag: value(child) for child in element}
        if (
            fields.get("subsystem") == "com.floodlight.app"
            and fields.get("event-time")
            and fields.get("event-type")
            and fields.get("signpost-name")
            and fields.get("os-signpost-identifier")
        ):
            timestamp = int(fields["event-time"])
            name = fields["signpost-name"]
            identifier = fields["os-signpost-identifier"]
            event_type = fields["event-type"]
            first_timestamp = timestamp if first_timestamp is None else min(first_timestamp, timestamp)
            last_timestamp = timestamp if last_timestamp is None else max(last_timestamp, timestamp)

            key = (name, identifier)
            if event_type == "Begin":
                begins[key] = timestamp
            elif event_type == "End" and key in begins:
                durations[name].append((timestamp - begins.pop(key)) / 1_000_000)

        element.clear()


def percentile(values, fraction):
    ordered = sorted(values)
    index = min(len(ordered) - 1, math.ceil(len(ordered) * fraction) - 1)
    return ordered[index]


summary = {}
for name, samples in sorted(durations.items()):
    summary[name] = {
        "count": len(samples),
        "mean_ms": round(statistics.fmean(samples), 3),
        "median_ms": round(statistics.median(samples), 3),
        "p95_ms": round(percentile(samples, 0.95), 3),
        "max_ms": round(max(samples), 3),
        "samples_ms": [round(sample, 3) for sample in samples],
    }

print(
    json.dumps(
        {
            "measurement_window": {
                "first_seconds": (
                    round(first_timestamp / 1_000_000_000, 6)
                    if first_timestamp is not None
                    else None
                ),
                "last_seconds": (
                    round(last_timestamp / 1_000_000_000, 6)
                    if last_timestamp is not None
                    else None
                ),
            },
            "intervals": summary,
            "unclosed_intervals": len(begins),
        },
        indent=2,
    )
)
