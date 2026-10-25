.PHONY: check

# Builds the packages and runs the tests, the checks of the flake.
check:
	nix flake check --print-build-logs
