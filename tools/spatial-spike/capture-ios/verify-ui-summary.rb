#!/usr/bin/env ruby
require 'json'

EXPECTED = {
  'result' => 'Passed',
  'totalTestCount' => 3,
  'passedTests' => 3,
  'failedTests' => 0,
  'skippedTests' => 0,
  'expectedFailures' => 0
}.freeze

if ARGV == ['--self-test']
  require 'open3'
  require 'rbconfig'
  # Synthetic result summaries test this release gate, never the camera or app.
  invalid = [
    EXPECTED.merge('passedTests' => 2, 'skippedTests' => 1),
    EXPECTED.merge('result' => 'Failed'),
    EXPECTED.merge('totalTestCount' => 2),
    EXPECTED.merge('passedTests' => 2),
    EXPECTED.merge('failedTests' => 1),
    EXPECTED.merge('expectedFailures' => 1),
    EXPECTED.reject { |key, _| key == 'skippedTests' },
    EXPECTED.reject { |key, _| key == 'expectedFailures' }
  ].map { |summary| JSON.generate(summary) } + ['not JSON', '[]']
  invalid.each do |input|
    _, _, status = Open3.capture3(RbConfig.ruby, __FILE__, stdin_data: input)
    abort 'FAIL: malformed/incomplete UI summary did not fail with exit 1' unless status.exitstatus == 1
  end
  _, _, status = Open3.capture3(RbConfig.ruby, __FILE__, stdin_data: JSON.generate(EXPECTED))
  abort 'FAIL: the exact passing UI summary was rejected' unless status.success?
  puts "PASS: UI-summary gate rejects #{invalid.length} invalid summaries and accepts the exact complete result"
  exit 0
end

abort 'FAIL: unexpected summary-check arguments' unless ARGV.empty?
begin
  result = JSON.parse(STDIN.read)
rescue JSON::ParserError
  abort 'FAIL: UI result summary is not valid JSON'
end
unless result.is_a?(Hash) && EXPECTED.all? { |key, value| result[key] == value }
  abort 'FAIL: expected Passed, total 3, passed 3, failed 0, skipped 0, expected failures 0'
end
puts 'PASS: 3 asserting simulator UI tests, 0 failures, 0 skipped, 0 expected failures'
