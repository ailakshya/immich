#!/bin/sh
# Runs the UploadPlan checks on the Mac (no device or simulator needed).
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d)
swiftc -o "$out/upload_plan_check" UploadExtension/UploadPlan.swift scripts/upload_plan_check/main.swift
"$out/upload_plan_check"
