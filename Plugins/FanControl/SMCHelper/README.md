This directory holds the source for the bundled Fan Control SMC helper.

The helper binary is built as `mactools-fan-smc-helper` and copied into
`FanControl.bundle/Contents/Resources/SMCHelper/` by the generated Xcode
project.

Write commands require an effective user ID of `0` and return a nonzero exit
status if the process was not elevated or if the requested SMC bytes cannot be
read back after writing. Use `mactools-fan-smc-helper identity` to print the
real and effective user/group IDs when diagnosing installation problems.
