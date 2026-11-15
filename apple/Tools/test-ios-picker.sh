#!/bin/sh
# Pass a booted, English-language iPhone simulator UUID to exercise the Files picker.
set -eu
device="${1:?Provide a booted iPhone simulator UUID}"
cd "$(dirname "$0")/.."
provider="$(xcrun simctl get_app_container "$device" com.apple.DocumentsApp groups | awk -F "\t" '$1 == "group.com.apple.FileProvider.LocalStorage" {print $2}')"
test -d "$provider/File Provider Storage"
fixture="$(mktemp -d "$provider/File Provider Storage/RoomReset-QA.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
printf 'Fixture document\n' > "$fixture/Note.txt"
printf 'Fixture archive placeholder\n' > "$fixture/Example.zip"
TEST_RUNNER_ROOMRESET_FIXTURE="$(basename "$fixture")" xcodebuild \
    -project RoomReset.xcodeproj -scheme RoomResetIOS -destination "id=$device" \
    -parallel-testing-enabled NO -derivedDataPath "${ROOMRESET_TEST_BUILD:-/tmp/roomreset-ios-test}" \
    -jobs 2 -collect-test-diagnostics never -only-testing:IOSPickerTests test
test "$(cat "$fixture/Note.txt")" = "Fixture document"
test "$(cat "$fixture/Example.zip")" = "Fixture archive placeholder"
