{ runCommand, writers, broker }:

let
  test = writers.writePython3 "claudevm-broker-test" { } ./broker-test.py;
in
runCommand "claudevm-broker-test" { } ''
  ${test} ${broker}/bin/claudevm-broker
  touch "$out"
''
