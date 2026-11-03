# Third-party sources

AppleSiliconDDC by @waydabber (MIT): https://github.com/waydabber/AppleSiliconDDC

Pinned upstream commit: `67ff964ab8123d9d35fadf7d8e1a7c677d31da14`.
Library and Objective-C bridge copied unchanged. License is in `AppleSiliconDDC/LICENSE`.
No Swift ArgumentParser or network package resolution is needed to build InputBridge.

The read-only helper uses AppleSiliconDDC's service discovery. Its GetVCP packet
transport is adapted from that library, with validation of opcode, length, result,
feature, type and checksum, and independent transport success checks. It exports
no SetVCP command. Each invocation exits to release IOKit resources.

Display enable/disable uses the same private `CGSConfigureDisplayEnabled`
entry point used by displayplacer, loaded dynamically. Mirroring uses public
Quartz configuration APIs. No displayplacer code is copied into the application.
Reference: https://github.com/jakehilborn/displayplacer
(inspected commit `c23026eb3d73000eb1a14b45d82fd6dd08c921f5`).
The separately cloned diagnostic utility is under ignored `Vendor/`.
