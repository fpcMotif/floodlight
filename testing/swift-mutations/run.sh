#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$ROOT/.build/swift-mutations
APP=$WORK/floodlight
PATCHES=$ROOT/testing/swift-mutations/patches
SCRATCH=$WORK/build

rm -rf "$WORK"
mkdir -p "$APP"
git -C "$ROOT" archive HEAD | tar -x -C "$APP"
git -C "$APP" init --quiet
git -C "$APP" add .
git -C "$APP" -c user.name=mutation-control -c user.email=mutation@invalid commit --quiet \
    --message=baseline
swift package --package-path "$APP" resolve

declare -a CAMPAIGN=(
    "stale-result-acceptance.patch|SearchCoordinatorIntegrationTests.supersededCompletionCannotReplaceCurrentPublication"
    "failed-scope-publication.patch|SourceSearchEngineTests.failedScopeChangeResumesActiveQueryOnSameStream"
    "failed-open-learning.patch|SelectedResultActionPerformerTests.failedApplicationOpenDoesNotRecordOrLearn"
    "originating-query-capture.patch|SelectedResultActionPerformerTests.independentOpensKeepTheirOwnItemAndQuery"
    "cancelled-independent-opens.patch|SelectedResultActionPerformerTests.independentOpensRetainIdentityAcrossReverseCompletion"
    "bypassed-running-application-fallback.patch|SelectedResultActionPerformerTests.successfulApplicationFallbackRecordsRecencyAndLearningAfterOpen"
)

BASELINE_FILTER=$(printf '%s\n' "${CAMPAIGN[@]}" | cut -d '|' -f 2 | paste -sd '|' -)
rm -rf "$SCRATCH"
swift test --package-path "$APP" --scratch-path "$SCRATCH" --filter "$BASELINE_FILTER"

for entry in "${CAMPAIGN[@]}"; do
    patch=${entry%%|*}
    test_name=${entry#*|}
    git -C "$APP" apply --check "$PATCHES/$patch"
    git -C "$APP" apply "$PATCHES/$patch"
    rm -rf "$SCRATCH"
    set +e
    swift test --package-path "$APP" --scratch-path "$SCRATCH" --filter "$test_name" \
        > "$WORK/$patch.log" 2>&1
    status=$?
    set -e
    git -C "$APP" apply --reverse "$PATCHES/$patch"
    if [ "$status" -eq 0 ]; then
        echo "error: $patch survived $test_name" >&2
        exit 1
    fi
    printf 'caught: %s by %s\n' "$patch" "$test_name"
done

printf '%s\n' "Swift mutations: 6 caught, 0 missed, 0 timed out, 0 unviable"
