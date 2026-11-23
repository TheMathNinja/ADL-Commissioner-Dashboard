# Zero-spend incident recovery

The existing **Email league workflow failures** job owns detection, verified
recovery, incident deduplication and email. It does not dispatch a second
repair workflow, invoke a model, add a runner, or send separate fixer mail.

The reporter can recover safe, known cases using deterministic routines. In
particular, it reads oversized state by its immutable Git blob and compacts
routine success acknowledgements when the serialized state reaches 950 KB.
It keeps failure evidence, exact recovery and association records, and every
SMTP reservation and receipt. It rereads and merges on write conflicts. The
size threshold is a guard, not a guarantee: if the retained evidence itself
outgrows the inline API, the independent reader still needs the blob fallback.

The normal owner email can identify a prior incident with the same failed
step and known error fingerprint. That context neither suppresses the current
incident nor asserts recovery. Unrecognized failures follow the existing
reporting rules. Only explicitly implemented and tested repairs run on their
own. New fixes and anything that could change functionality, run with elevated
permissions, or replay business writes require review. No model or bot has
been granted production write access as a result of this integration.

Before retiring the desktop schedule, verify the normal reporter on the exact
release, all four repository reads, exact Guardian completion and missed-check
handling, scrape freshness, and the separately scheduled Apps Script health
reader. A GitHub run or successful dispatch does not prove Apps Script read the
receipts. Keep native safety-net email settings unchanged.
