#!/usr/bin/env bash
# path-kinds.sh — shared path classification for the review-cadence scripts.
# SOURCED (not executed) by core/infra/council-threshold.sh and core/infra/review-tier.sh so
# both judge "is this path docs?" and "is this path a test?" with ONE definition instead of two
# hand-synced copies. Pure functions, no output, no git, bash 3.2 safe (no ${var,,}, no assoc
# arrays); regexes live in variables because bash 3.2 mis-parses some inline [[ =~ ]] literals.
#
#   is_docs_path <path>   0 if the path is documentation / non-code in this repo's sense:
#                         .md, .css/.scss, docs/ or assets/ segment, LICENSE, .txt.
#                         (.json/.toml/.sh/.py and templates are CODE here — hooks.json and
#                         templates are behavior.)
#   is_test_path <path>   0 if the path is a test artifact: a tests/ test/ __tests__/ spec/
#                         evals/ directory segment, or a file named *-test.* *_test.* *.test.*
#                         *.spec.* test_*.py.
#   is_review_light_path  0 if either of the above (what council-threshold.sh leaves out of
#                         its line/file counts; risk classification still sees every path).

_PK_DOCS_RE_MD='\.md$'
_PK_DOCS_RE_CSS='\.(css|scss)$'
_PK_DOCS_RE_DIR='(^|/)(docs|assets)/'
_PK_DOCS_RE_LICENSE='(^|/)LICENSE$'
_PK_DOCS_RE_TXT='\.txt$'
_PK_TEST_RE_DIR='(^|/)(tests?|__tests__|spec|evals)/'
_PK_TEST_RE_FILE='(^|/)(test_[^/]*\.py|[^/]*[-_.]test\.[^/]+|[^/]*\.spec\.[^/]+)$'

is_docs_path() {
  local p="$1"
  [[ "$p" =~ $_PK_DOCS_RE_MD ]] && return 0
  [[ "$p" =~ $_PK_DOCS_RE_CSS ]] && return 0
  [[ "$p" =~ $_PK_DOCS_RE_DIR ]] && return 0
  [[ "$p" =~ $_PK_DOCS_RE_LICENSE ]] && return 0
  [[ "$p" =~ $_PK_DOCS_RE_TXT ]] && return 0
  return 1
}

is_test_path() {
  local p="$1"
  [[ "$p" =~ $_PK_TEST_RE_DIR ]] && return 0
  [[ "$p" =~ $_PK_TEST_RE_FILE ]] && return 0
  return 1
}

is_review_light_path() {
  is_docs_path "$1" || is_test_path "$1"
}
